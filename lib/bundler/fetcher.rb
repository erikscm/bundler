require 'bundler/vendored_persistent'
require 'securerandom'
require 'cgi'

module Bundler

  # Handles all the fetching with the rubygems server
  class Fetcher
    # This error is raised when it looks like the network is down
    class NetworkDownError < HTTPError; end
    # This error is raised if the API returns a 413 (only printed in verbose)
    class FallbackError < HTTPError; end
    # This is the error raised if OpenSSL fails the cert verification
    class CertificateFailureError < HTTPError
      def initialize(remote_uri)
        super "Could not verify the SSL certificate for #{remote_uri}.\nThere" \
          " is a chance you are experiencing a man-in-the-middle attack, but" \
          " most likely your system doesn't have the CA certificates needed" \
          " for verification. For information about OpenSSL certificates, see" \
          " bit.ly/ruby-ssl. To connect without using SSL, edit your Gemfile" \
          " sources and change 'https' to 'http'."
      end
    end
    # This is the error raised when a source is HTTPS and OpenSSL didn't load
    class SSLError < HTTPError
      def initialize(msg = nil)
        super msg || "Could not load OpenSSL.\n" \
            "You must recompile Ruby with OpenSSL support or change the sources in your " \
            "Gemfile from 'https' to 'http'. Instructions for compiling with OpenSSL " \
            "using RVM are available at rvm.io/packages/openssl."
      end
    end
    # This error is raised if HTTP authentication is required, but not provided.
    class AuthenticationRequiredError < HTTPError
      def initialize(remote_uri)
        super "Authentication is required for #{remote_uri}.\n" \
          "Please supply credentials for this source. You can do this by running:\n" \
          " bundle config #{remote_uri} username:password"
      end
    end
    # This error is raised if HTTP authentication is provided, but incorrect.
    class BadAuthenticationError < HTTPError
      def initialize(remote_uri)
        super "Bad username or password for #{remote_uri}.\n" \
          "Please double-check your credentials and correct them."
      end
    end

    # Exceptions classes that should bypass retry attempts. If your password didn't work the
    # first time, it's not going to the third time.
    AUTH_ERRORS = [AuthenticationRequiredError, BadAuthenticationError]

    class << self
      attr_accessor :disable_endpoint, :api_timeout, :redirect_limit, :max_retries

      def download_gem_from_uri(spec, uri)
        spec.fetch_platform

        download_path = Bundler.requires_sudo? ? Bundler.tmp(spec.full_name) : Bundler.rubygems.gem_dir
        gem_path = "#{Bundler.rubygems.gem_dir}/cache/#{spec.full_name}.gem"

        FileUtils.mkdir_p("#{download_path}/cache")
        Bundler.rubygems.download_gem(spec, uri, download_path)

        if Bundler.requires_sudo?
          Bundler.mkdir_p "#{Bundler.rubygems.gem_dir}/cache"
          Bundler.sudo "mv #{Bundler.tmp(spec.full_name)}/cache/#{spec.full_name}.gem #{gem_path}"
        end

        gem_path
      end

      def user_agent
        @user_agent ||= begin
          ruby = Bundler.ruby_version

          agent = "bundler/#{Bundler::VERSION}"
          agent << " rubygems/#{Gem::VERSION}"
          agent << " ruby/#{ruby.version}"
          agent << " (#{ruby.host})"
          agent << " command/#{ARGV.first}"

          if ruby.engine != "ruby"
            # engine_version raises on unknown engines
            engine_version = ruby.engine_version rescue "???"
            agent << " #{ruby.engine}/#{engine_version}"
          end

          agent << " options/#{Bundler.settings.all.join(",")}"

          # add a random ID so we can consolidate runs server-side
          agent << " " << SecureRandom.hex(8)

          # add any user agent strings set in the config
          extra_ua = Bundler.settings[:user_agent]
          agent << " " << extra_ua if extra_ua

          agent
        end
      end

    end

    def initialize(remote_uri)
      @redirect_limit = 5  # How many redirects to allow in one request
      @api_timeout    = 10 # How long to wait for each API call
      @max_retries    = 3  # How many retries for the API call

      @anonymizable_uri = configured_uri_for(remote_uri)

      Socket.do_not_reverse_lookup = true
      connection # create persistent connection
    end

    def connection
      @connection ||= begin
        needs_ssl = remote_uri.scheme == "https" ||
          Bundler.settings[:ssl_verify_mode] ||
          Bundler.settings[:ssl_client_cert]
        raise SSLError if needs_ssl && !defined?(OpenSSL::SSL)

        con = Net::HTTP::Persistent.new 'bundler', :ENV

        if remote_uri.scheme == "https"
          con.verify_mode = (Bundler.settings[:ssl_verify_mode] ||
            OpenSSL::SSL::VERIFY_PEER)
          con.cert_store = bundler_cert_store
        end

        if Bundler.settings[:ssl_client_cert]
          pem = File.read(Bundler.settings[:ssl_client_cert])
          con.cert = OpenSSL::X509::Certificate.new(pem)
          con.key  = OpenSSL::PKey::RSA.new(pem)
        end

        con.read_timeout = @api_timeout
        con.override_headers["User-Agent"] = self.class.user_agent
        con
      end
    end

    def uri
      @anonymizable_uri.without_credentials
    end

    # fetch a gem specification
    def fetch_spec(spec)
      spec = spec - [nil, 'ruby', '']
      spec_file_name = "#{spec.join '-'}.gemspec"

      uri = URI.parse("#{remote_uri}#{Gem::MARSHAL_SPEC_DIR}#{spec_file_name}.rz")
      if uri.scheme == 'file'
        Bundler.load_marshal Gem.inflate(Gem.read_binary(uri.path))
      elsif cached_spec_path = gemspec_cached_path(spec_file_name)
        Bundler.load_gemspec(cached_spec_path)
      else
        Bundler.load_marshal Gem.inflate(fetch(uri))
      end
    rescue MarshalError
      raise HTTPError, "Gemspec #{spec} contained invalid data.\n" \
        "Your network or your gem server is probably having issues right now."
    end

    # cached gem specification path, if one exists
    def gemspec_cached_path spec_file_name
      paths = Bundler.rubygems.spec_cache_dirs.map { |dir| File.join(dir, spec_file_name) }
      paths = paths.select {|path| File.file? path }
      paths.first
    end

    # return the specs in the bundler format as an index
    def specs(gem_names, source)
      old = Bundler.rubygems.sources
      index = Index.new

      if gem_names && use_api
        specs = fetch_remote_specs(gem_names)
      end

      if specs.nil?
        # API errors mean we should treat this as a non-API source
        @use_api = false

        specs = Bundler::Retry.new("source fetch", AUTH_ERRORS).attempts do
          fetch_all_remote_specs
        end
      end

      specs[remote_uri].each do |name, version, platform, dependencies|
        next if name == 'bundler'
        spec = nil
        if dependencies
          spec = EndpointSpecification.new(name, version, platform, dependencies)
        else
          spec = RemoteSpecification.new(name, version, platform, self)
        end
        spec.source = source
        spec.source_uri = @anonymizable_uri
        index << spec
      end

      index
    rescue CertificateFailureError => e
      Bundler.ui.info "" if gem_names && use_api # newline after dots
      raise e
    ensure
      Bundler.rubygems.sources = old
    end

    # fetch index
    def fetch_remote_specs(gem_names, full_dependency_list = [], last_spec_list = [])
      query_list = gem_names - full_dependency_list

      # only display the message on the first run
      if Bundler.ui.debug?
        Bundler.ui.debug "Query List: #{query_list.inspect}"
      else
        Bundler.ui.info ".", false
      end

      return {remote_uri => last_spec_list} if query_list.empty?

      remote_specs = Bundler::Retry.new("dependency api", AUTH_ERRORS).attempts do
        fetch_dependency_remote_specs(query_list)
      end

      spec_list, deps_list = remote_specs
      returned_gems = spec_list.map {|spec| spec.first }.uniq
      fetch_remote_specs(deps_list, full_dependency_list + returned_gems, spec_list + last_spec_list)
    rescue HTTPError, MarshalError, GemspecError
      Bundler.ui.info "" unless Bundler.ui.debug? # new line now that the dots are over
      Bundler.ui.debug "could not fetch from the dependency API, trying the full index"
      @use_api = false
      return nil
    end

    def use_api
      return @use_api if defined?(@use_api)

      if remote_uri.scheme == "file" || Bundler::Fetcher.disable_endpoint
        @use_api = false
      elsif fetch(dependency_api_uri)
        @use_api = true
      end
    rescue NetworkDownError => e
      raise HTTPError, e.message
    rescue AuthenticationRequiredError
      # We got a 401 from the server. Don't fall back to the full index, just fail.
      raise
    rescue HTTPError
      @use_api = false
    end

    def inspect
      "#<#{self.class}:0x#{object_id} uri=#{uri}>"
    end

  private

    HTTP_ERRORS = [
      Timeout::Error, EOFError, SocketError, Errno::ENETDOWN,
      Errno::EINVAL, Errno::ECONNRESET, Errno::ETIMEDOUT, Errno::EAGAIN,
      Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError,
      Net::HTTP::Persistent::Error
    ]

    def fetch(uri, counter = 0)
      raise HTTPError, "Too many redirects" if counter >= @redirect_limit

      response = request(uri)
      Bundler.ui.debug("HTTP #{response.code} #{response.message}")

      case response
      when Net::HTTPRedirection
        new_uri = URI.parse(response["location"])
        if new_uri.host == uri.host
          new_uri.user = uri.user
          new_uri.password = uri.password
        end
        fetch(new_uri, counter + 1)
      when Net::HTTPSuccess
        response.body
      when Net::HTTPRequestEntityTooLarge
        raise FallbackError, response.body
      when Net::HTTPUnauthorized
        raise AuthenticationRequiredError, remote_uri.host
      else
        raise HTTPError, "#{response.class}: #{response.body}"
      end
    end

    def request(uri)
      Bundler.ui.debug "HTTP GET #{uri}"
      req = Net::HTTP::Get.new uri.request_uri
      if uri.user
        user = CGI.unescape(uri.user)
        password = uri.password ? CGI.unescape(uri.password) : nil
        req.basic_auth(user, password)
      end
      connection.request(uri, req)
    rescue OpenSSL::SSL::SSLError
      raise CertificateFailureError.new(uri)
    rescue *HTTP_ERRORS => e
      Bundler.ui.trace e
      case e.message
      when /host down:/, /getaddrinfo: nodename nor servname provided/
        raise NetworkDownError, "Could not reach host #{uri.host}. Check your network " \
        "connection and try again."
      else
        raise HTTPError, "Network error while fetching #{uri}"
      end
    end

    def dependency_api_uri(gem_names = [])
      uri = fetch_uri + "api/v1/dependencies"
      uri.query = "gems=#{URI.encode(gem_names.join(","))}" if gem_names.any?
      uri
    end

    # fetch from Gemcutter Dependency Endpoint API
    def fetch_dependency_remote_specs(gem_names)
      Bundler.ui.debug "Query Gemcutter Dependency Endpoint API: #{gem_names.join(',')}"
      gem_list = []
      deps_list = []

      gem_names.each_slice(Source::Rubygems::API_REQUEST_LIMIT) do |names|
        marshalled_deps = fetch dependency_api_uri(names)
        gem_list += Bundler.load_marshal(marshalled_deps)
      end

      spec_list = gem_list.map do |s|
        dependencies = s[:dependencies].map do |name, requirement|
          dep = well_formed_dependency(name, requirement.split(", "))
          deps_list << dep.name
          dep
        end

        [s[:name], Gem::Version.new(s[:number]), s[:platform], dependencies]
      end

      [spec_list, deps_list.uniq]
    end

    # fetch from modern index: specs.4.8.gz
    def fetch_all_remote_specs
      old_sources = Bundler.rubygems.sources
      Bundler.rubygems.sources = [remote_uri.to_s]
      Bundler.rubygems.fetch_all_remote_specs
    rescue Gem::RemoteFetcher::FetchError, OpenSSL::SSL::SSLError => e
      case e.message
      when /certificate verify failed/
        raise CertificateFailureError.new(uri)
      when /401/
        raise AuthenticationRequiredError, remote_uri
      when /403/
        if remote_uri.userinfo
          raise BadAuthenticationError, remote_uri
        else
          raise AuthenticationRequiredError, remote_uri
        end
      else
        Bundler.ui.trace e
        raise HTTPError, "Could not fetch specs from #{uri}"
      end
    ensure
      Bundler.rubygems.sources = old_sources
    end

    def well_formed_dependency(name, *requirements)
      Gem::Dependency.new(name, *requirements)
    rescue ArgumentError => e
      illformed = 'Ill-formed requirement ["#<YAML::Syck::DefaultKey'
      raise e unless e.message.include?(illformed)
      puts # we shouldn't print the error message on the "fetching info" status line
      raise GemspecError,
        "Unfortunately, the gem #{s[:name]} (#{s[:number]}) has an invalid " \
        "gemspec. \nPlease ask the gem author to yank the bad version to fix " \
        "this issue. For more information, see http://bit.ly/syck-defaultkey."
    end

    def bundler_cert_store
      store = OpenSSL::X509::Store.new
      if Bundler.settings[:ssl_ca_cert]
        if File.directory? Bundler.settings[:ssl_ca_cert]
          store.add_path Bundler.settings[:ssl_ca_cert]
        else
          store.add_file Bundler.settings[:ssl_ca_cert]
        end
      else
        store.set_default_paths
        certs = File.expand_path("../ssl_certs/*.pem", __FILE__)
        Dir.glob(certs).each { |c| store.add_file c }
      end
      store
    end

  private

    def configured_uri_for(uri)
      uri = Bundler::Source.mirror_for(uri)
      config_auth = Bundler.settings[uri.to_s] || Bundler.settings[uri.host]
      AnonymizableURI.new(uri, config_auth)
    end

    def fetch_uri
      @fetch_uri ||= begin
        if remote_uri.host == "rubygems.org"
          uri = remote_uri.dup
          uri.host = "bundler.rubygems.org"
          uri
        else
          remote_uri
        end
      end
    end

    def remote_uri
      @anonymizable_uri.original_uri
    end
  end
end
