#
# Author:: Adam Jacob (<adam@chef.io>)
# Copyright:: Copyright 2010-2019, Chef Software Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "chef/knife"
require "chef/knife/data_bag_secret_options"
require "erubis"
require "chef/knife/bootstrap/chef_vault_handler"
require "chef/knife/bootstrap/client_builder"
require "chef/util/path_helper"
require "chef/knife/bootstrap/options"

class Chef
  class Knife
    class Bootstrap < Knife
      include DataBagSecretOptions

      # Command line flags and options for bootstrap - there's a large number of them
      # so we'll keep this file a little smaller by splitting them out.
      include Bootstrap::Options

      attr_accessor :client_builder
      attr_accessor :chef_vault_handler
      attr_reader   :target_host

      deps do
        require "chef/json_compat"
        require "tempfile"
        require "chef_core/text" # i18n and standardized error structures
        require "chef_core/target_host"
        require "chef_core/target_resolver"
      end

      banner "knife bootstrap [PROTOCOL://][USER@]FQDN (options)"

      def initialize(argv = [])
        super
        # TODO - these map cleanly to action support classes
        @client_builder = Chef::Knife::Bootstrap::ClientBuilder.new(
          chef_config: Chef::Config,
          knife_config: config,
          ui: ui
        )
        @chef_vault_handler = Chef::Knife::Bootstrap::ChefVaultHandler.new(
          knife_config: config,
          ui: ui
        )
      end

      # The default bootstrap template to use to bootstrap a server.
      # This is a public API hook which knife plugins use or inherit and override.
      #
      # @return [String] Default bootstrap template
      def default_bootstrap_template
        if target_host.base_os == :windows
          "windows-chef-client-msi"
        else
          "chef-full"
        end
      end

      def host_descriptor
        Array(@name_args).first
      end

      # The server_name is the DNS or IP we are going to connect to, it is not necessarily
      # the node name, the fqdn, or the hostname of the server.  This is a public API hook
      # which knife plugins use or inherit and override.
      #
      # @return [String] The DNS or IP that bootstrap will connect to
      def server_name
        if host_descriptor
          @server_name ||= host_descriptor.split("@").reverse[0]
        end
      end


      # @return [String] The CLI specific bootstrap template or the default
      def bootstrap_template
        # Allow passing a bootstrap template or use the default
        config[:bootstrap_template] || default_bootstrap_template
      end

      def find_template
        template = bootstrap_template

        # Use the template directly if it's a path to an actual file
        if File.exists?(template)
          Chef::Log.trace("Using the specified bootstrap template: #{File.dirname(template)}")
          return template
        end

        # Otherwise search the template directories until we find the right one
        bootstrap_files = []
        bootstrap_files << File.join(File.dirname(__FILE__), "bootstrap/templates", "#{template}.erb")
        bootstrap_files << File.join(Knife.chef_config_dir, "bootstrap", "#{template}.erb") if Chef::Knife.chef_config_dir
        Chef::Util::PathHelper.home(".chef", "bootstrap", "#{template}.erb") { |p| bootstrap_files << p }
        bootstrap_files << Gem.find_files(File.join("chef", "knife", "bootstrap", "#{template}.erb"))
        bootstrap_files.flatten!

        template_file = Array(bootstrap_files).find do |bootstrap_template|
          Chef::Log.trace("Looking for bootstrap template in #{File.dirname(bootstrap_template)}")
          File.exists?(bootstrap_template)
        end

        unless template_file
          ui.info("Can not find bootstrap definition for #{template}")
          raise Errno::ENOENT
        end

        Chef::Log.trace("Found bootstrap template in #{File.dirname(template_file)}")

        template_file
      end

      def secret
        @secret ||= encryption_secret_provided_ignore_encrypt_flag? ? read_secret : nil
      end

      def bootstrap_context
        @bootstrap_context ||=
          if target_host.base_os == :windows

            require "chef/knife/core/windows_bootstrap_context"
            Knife::Core::WindowsBootstrapContext.new(config, config[:run_list],
                                                     Chef::Config, secret)
          else
            require "chef/knife/core/bootstrap_context"
            Knife::Core::BootstrapContext.new(config, config[:run_list],
                                              Chef::Config, secret)
          end
      end

      def first_boot_attributes
        @config[:first_boot_attributes] || @config[:first_boot_attributes_from_file] || {}
      end

      def render_template
        @config[:first_boot_attributes] = first_boot_attributes
        template_file = find_template
        template = IO.read(template_file).chomp
        Erubis::Eruby.new(template).evaluate(bootstrap_context)
      end

      def run
        if @config[:first_boot_attributes] && @config[:first_boot_attributes_from_file]
          raise Chef::Exceptions::BootstrapCommandInputError
        end

        validate_name_args!
        validate_options!

        $stdout.sync = true

        bootstrap_path = nil

        # chef-vault integration must use the new client-side hawtness, otherwise to use the
        # new client-side hawtness, just delete your validation key.
        if chef_vault_handler.doing_chef_vault? ||
            (Chef::Config[:validation_key] && !File.exist?(File.expand_path(Chef::Config[:validation_key])))

          unless config[:chef_node_name]
            ui.error("You must pass a node name with -N when bootstrapping with user credentials")
            exit 1
          end

          client_builder.run

          chef_vault_handler.run(client_builder.client)

        else
          ui.info("Doing old-style registration with the validation key at #{Chef::Config[:validation_key]}...")
          ui.info("Delete your validation key in order to use your user credentials instead")
          ui.info("")
        end

        connect!

        # Now that we have a connected target_host, we can use (by referencing it...)
        # "bootstrap_context".
        unless client_builder.client_path.nil?
          bootstrap_context.client_pem = client_builder.client_path
        end

        bootstrap_path = render_and_upload_bootstrap
        ui.info("Bootstrapping #{ui.color(server_name, :bold)}")
        r = target_host.run_command(bootstrap_command(bootstrap_path)) do |data|
          ui.msg("#{ui.color(" [#{target_host.hostname}]", :cyan)} #{data}")
        end
        if r.exit_status != 0
          ui.error("The following error occurred on #{server_name}:")
          ui.error(r.stderr)
          exit 1
        end
      ensure
        target_host.del_file(bootstrap_path) if target_host && bootstrap_path
      end

      def connect!
        ui.info("Connecting to #{ui.color(server_name, :bold)}")
        opts = connection_opts.dup
        do_connect(opts) # rescue: TargetResolverError
      rescue => e
        # Ugh. TODO 1: Train raises a Train::Transports::SSHFailed for a number of different errors. chef_core makes that
        # a more general ConnectionFailed, with an error code based on the specific error text/reason provided from trainm.
        # This means we have to look three layers intot he exception to find out what actually happened instead of just
        # looking at the exception type
        #
        # It doesn't help to provide our own error if it does't let the caller know what they need to identify the problem.
        # Let's update chef_core to be a bit smarter about resolving the errors to an appropriate exception type
        # (eg ChefCore::ConnectionFailed::AuthError or similar) that will work across protocols, instead of just a single
        # ConnectionFailure type
        #
        # # TODO 2 - it is possible for train to automatically do the reprompt for password
        #            but that will take a little digging through the train ssh protocol layer.
        if e.cause && e.cause.cause && e.cause.cause.class == Net::SSH::AuthenticationFailed
          if opts[:password]
            raise
          else
            ui.warn("Failed to authenticate #{target_host.user} - trying password auth")
            password = ui.ask("Enter password for #{target_host.user}@#{target_host.hostname}: ") do |q|
              q.echo = false
            end
            update_connection_opts_for_forced_password(opts, password)
            do_connect(opts)
          end
        else
          raise
        end
      end

      def do_connect(conn_options)
        # Resolve the given host name to a TargetHost instance. We will limit
        # the number of hosts to 1 (effectivly eliminating wildcard support) since
        # we only support running bootstrap against one host at a time.
        resolver = ChefCore::TargetResolver.new(host_descriptor, config[:protocol] || "ssh",
                                                conn_options, max_expanded_targets: 1)
        @target_host = resolver.targets.first
        @target_host.connect!
        @target_host
      end

      # fail if the server_name is nil
      def validate_name_args!
        if server_name.nil?
          ui.error("Must pass an FQDN or ip to bootstrap")
          exit 1
        end
      end

      # Ensure options are valid by checking policyfile values.
      #
      # The method call will cause the program to exit(1) if:
      #   * Only one of --policy-name and --policy-group is specified
      #   * Policyfile options are set and --run-list is set as well
      #
      # @return [TrueClass] If options are valid.
      def validate_options!
        if incomplete_policyfile_options?
          ui.error("--policy-name and --policy-group must be specified together")
          exit 1
        elsif policyfile_and_run_list_given?
          ui.error("Policyfile options and --run-list are exclusive")
          exit 1
        end
        true
      end

      # Createa configuration object based on setup a Chef::Knife::Ssh object using the passed config options
      # Includes connection information for both supported protocols at this time - unused config is ignored.
      #
      # @return a configuration hash suitable for connecting to the remote host via TargetHost.
      def connection_opts
        # Mapping of our options to TargetHost/train options - they're pretty similar with removal of
        # the ssh- prefix, but there's more to correct
        opts = {
          port: config[:port], # Default if it's not in the connection string
          user: config[:user], #  "
          password: config[:password], # TODO - check if we need to exclude if not set, diff behavior for nil?
          forward_agent: config[:forward_agent] || false ,
          logger:  Chef::Log,
          key_files: [],
          # WinRM options - they will be ignored for ssh
          # TODO train will throw if this is not valid, should be OK as-is
          winrm_transport: config[:winrm_transport],
          self_signed: config[:winrm_no_verify_cert] === true,
          winrm_basic_auth_only: config[:winrm_basic_auth_only],
          ssl: config[:winrm_ssl],
          ssl_peer_fingerprint: config[:winrm_ssl_peer_fingerprint]

          # NOTE: 'ssl' true is different from using the ssl auth protocol which supoorts
          #       using client cert+key (though we dongtgt
        }

        if opts[:ssh_identity_file]
          opts[:keys_only] = true
          opts[:key_files] << config[:ssh_identity_file]
        end

        if config[:ssh_gateway]
          gw_host, gw_user = config[:ssh_gateway].split("@").reverse
          gw_host, gw_port = gw_host.split(":")
          opts[:bastion_host] = gw_host
          opts[:bastion_port] = gw_port
          opts[:bastion_user] = gw_user
          if config[:ssh_gatway_identity]
            opts[:key_files] << config[:ssh_gateway_identity]
          end
        end

        if config[:use_sudo]
          opts[:sudo] = true
          if opts[:use_sudo_password]
            opts[:sudo_password] = config[:password]
          end
          if opts[:preserve_home]
             opts[:sudo_options] = "-H"
          end
        end

        # REVIEWERS - maybe we combine this and winrm_no_verify_cert flags into "--no-verify-target"?
        opts[:host_key_verify] = config[:host_key_verify].nil? ? true : config[:host_key_verify]

        if config[:password]
          opts[:password] = config[:password]
        end


        opts[:winrm_transport] = config[:winrm_auth_method]
        if config[:winrm_auth_method] == "kerberos"
          opts[:kerberos_service] = config[:kerberos_service]
          opts[:kerberos_realm] = config[:kerberos_realm]
        end

        opts[:ca_trust_path] = config[:ca_trust_path]

        opts[:winrm_basic_auth_only] = config[:winrm_basic_auth_only] if config[:winrm_basic_auth_only]
        opts
      end


      def update_connection_opts_for_forced_password(opts, password)
        opts[:password] = password
        opts[:non_interactive] = false
        opts[:keys_only] = false
        opts[:key_files] = nil
        opts[:auth_methods] = [:password, :keyboard_interactive]
      end

      def render_and_upload_bootstrap
        content = render_template
        script_name = target_host.base_os == :windows ? "bootstrap.bat" : "bootstrap.sh"
        remote_path = target_host.normalize_path(File.join(target_host.temp_dir, script_name))
        target_host.save_as_remote_file(content, remote_path)
        remote_path
      end


      # build the command string for bootrapping
      # @return String
      def bootstrap_command(remote_path)
        if target_host.base_os == :windows
          "cmd.exe /C #{remote_path}"
        else
          "sh #{remote_path} "
        end
      end

      private

      # True if policy_name and run_list are both given
      def policyfile_and_run_list_given?
        run_list_given? && policyfile_options_given?
      end

      def run_list_given?
        !config[:run_list].nil? && !config[:run_list].empty?
      end

      def policyfile_options_given?
        !!config[:policy_name]
      end

      # True if one of policy_name or policy_group was given, but not both
      def incomplete_policyfile_options?
        (!!config[:policy_name] ^ config[:policy_group])
      end

    end
  end
end
