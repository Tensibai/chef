#
# Author:: Ian Meyer (<ianmmeyer@gmail.com>)
# Copyright:: Copyright 2010-2016, Ian Meyer
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

require "spec_helper"

Chef::Knife::Bootstrap.load_deps
require "net/ssh"

describe Chef::Knife::Bootstrap do
  let(:bootstrap_template) { nil }
  let(:stderr) { StringIO.new }
  let(:bootstrap_cli_options) { [ ] }
  let(:base_os) { :linux }
  let(:target_host) { double("TargetHost") }

  let(:knife) do
    Chef::Log.logger = Logger.new(StringIO.new)
    Chef::Config[:knife][:bootstrap_template] = bootstrap_template unless bootstrap_template.nil?

    k = Chef::Knife::Bootstrap.new(bootstrap_cli_options)
    allow(k.ui).to receive(:stderr).and_return(stderr)
    allow(k).to receive(:encryption_secret_provided_ignore_encrypt_flag?).and_return(false)
    allow(k).to receive(:target_host).and_return target_host
    k.merge_configs
    k
  end

  before do
    allow(target_host).to receive(:base_os).and_return base_os
  end

  context "#bootstrap_template" do
    it "should default to chef-full" do
      expect(knife.bootstrap_template).to be_a_kind_of(String)
      expect(File.basename(knife.bootstrap_template)).to eq("chef-full")
    end
  end

  context "#render_template - when using the chef-full default template" do
    let(:rendered_template) do
      knife.merge_configs
      knife.render_template
    end

    it "should render client.rb" do
      expect(rendered_template).to match("cat > /etc/chef/client.rb <<'EOP'")
      expect(rendered_template).to match("chef_server_url  \"https://localhost:443\"")
      expect(rendered_template).to match("validation_client_name \"chef-validator\"")
      expect(rendered_template).to match("log_location   STDOUT")
    end

    it "should render first-boot.json" do
      expect(rendered_template).to match("cat > /etc/chef/first-boot.json <<'EOP'")
      expect(rendered_template).to match('{"run_list":\[\]}')
    end

    context "and encrypted_data_bag_secret was provided" do
      it "should render encrypted_data_bag_secret file" do
        expect(knife).to receive(:encryption_secret_provided_ignore_encrypt_flag?).and_return(true)
        expect(knife).to receive(:read_secret).and_return("secrets")
        expect(rendered_template).to match("cat > /etc/chef/encrypted_data_bag_secret <<'EOP'")
        expect(rendered_template).to match('{"run_list":\[\]}')
        expect(rendered_template).to match(%r{secrets})
      end
    end
  end

  context "with --bootstrap-vault-item" do
    let(:bootstrap_cli_options) { [ "--bootstrap-vault-item", "vault1:item1", "--bootstrap-vault-item", "vault1:item2", "--bootstrap-vault-item", "vault2:item1" ] }
    it "sets the knife config cli option correctly" do
      expect(knife.config[:bootstrap_vault_item]).to eq({ "vault1" => %w{item1 item2}, "vault2" => ["item1"] })
    end
  end

  context "with --bootstrap-preinstall-command" do
    command = "while sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1; do\n   echo 'waiting for dpkg lock';\n   sleep 1;\n  done;"
    let(:bootstrap_cli_options) { [ "--bootstrap-preinstall-command", command ] }
    let(:rendered_template) do
      knife.merge_configs
      knife.render_template
    end
    it "configures the preinstall command in the bootstrap template correctly" do
      expect(rendered_template).to match(%r{command})
    end
  end

  context "with :bootstrap_template and :template_file cli options" do
    let(:bootstrap_cli_options) { [ "--bootstrap-template", "my-template", "other-template" ] }

    it "should select bootstrap template" do
      expect(File.basename(knife.bootstrap_template)).to eq("my-template")
    end
  end

  context "when finding templates" do
    context "when :bootstrap_template config is set to a file" do
      context "that doesn't exist" do
        let(:bootstrap_template) { "/opt/blah/not/exists/template.erb" }

        it "raises an error" do
          expect { knife.find_template }.to raise_error(Errno::ENOENT)
        end
      end

      context "that exists" do
        let(:bootstrap_template) { File.expand_path(File.join(CHEF_SPEC_DATA, "bootstrap", "test.erb")) }

        it "loads the given file as the template" do
          expect(Chef::Log).to receive(:trace)
          expect(knife.find_template).to eq(File.expand_path(File.join(CHEF_SPEC_DATA, "bootstrap", "test.erb")))
        end
      end
    end

    context "when :bootstrap_template config is set to a template name" do
      let(:bootstrap_template) { "example" }

      let(:builtin_template_path) { File.expand_path(File.join(File.dirname(__FILE__), "../../../lib/chef/knife/bootstrap/templates", "example.erb")) }

      let(:chef_config_dir_template_path) { "/knife/chef/config/bootstrap/example.erb" }

      let(:env_home_template_path) { "/env/home/.chef/bootstrap/example.erb" }

      let(:gem_files_template_path) { "/Users/schisamo/.rvm/gems/ruby-1.9.2-p180@chef-0.10/gems/knife-windows-0.5.4/lib/chef/knife/bootstrap/fake-bootstrap-template.erb" }

      def configure_chef_config_dir
        allow(Chef::Knife).to receive(:chef_config_dir).and_return("/knife/chef/config")
      end

      def configure_env_home
        allow(Chef::Util::PathHelper).to receive(:home).with(".chef", "bootstrap", "example.erb").and_yield(env_home_template_path)
      end

      def configure_gem_files
        allow(Gem).to receive(:find_files).and_return([ gem_files_template_path ])
      end

      before(:each) do
        expect(File).to receive(:exists?).with(bootstrap_template).and_return(false)
      end

      context "when file is available everywhere" do
        before do
          configure_chef_config_dir
          configure_env_home
          configure_gem_files

          expect(File).to receive(:exists?).with(builtin_template_path).and_return(true)
        end

        it "should load the template from built-in templates" do
          expect(knife.find_template).to eq(builtin_template_path)
        end
      end

      context "when file is available in chef_config_dir" do
        before do
          configure_chef_config_dir
          configure_env_home
          configure_gem_files

          expect(File).to receive(:exists?).with(builtin_template_path).and_return(false)
          expect(File).to receive(:exists?).with(chef_config_dir_template_path).and_return(true)

          it "should load the template from chef_config_dir" do
            knife.find_template.should eq(chef_config_dir_template_path)
          end
        end
      end

      context "when file is available in home directory" do
        before do
          configure_chef_config_dir
          configure_env_home
          configure_gem_files

          expect(File).to receive(:exists?).with(builtin_template_path).and_return(false)
          expect(File).to receive(:exists?).with(chef_config_dir_template_path).and_return(false)
          expect(File).to receive(:exists?).with(env_home_template_path).and_return(true)
        end

        it "should load the template from chef_config_dir" do
          expect(knife.find_template).to eq(env_home_template_path)
        end
      end

      context "when file is available in Gem files" do
        before do
          configure_chef_config_dir
          configure_env_home
          configure_gem_files

          expect(File).to receive(:exists?).with(builtin_template_path).and_return(false)
          expect(File).to receive(:exists?).with(chef_config_dir_template_path).and_return(false)
          expect(File).to receive(:exists?).with(env_home_template_path).and_return(false)
          expect(File).to receive(:exists?).with(gem_files_template_path).and_return(true)
        end

        it "should load the template from Gem files" do
          expect(knife.find_template).to eq(gem_files_template_path)
        end
      end

      context "when file is available in Gem files and home dir doesn't exist" do
        before do
          configure_chef_config_dir
          configure_gem_files
          allow(Chef::Util::PathHelper).to receive(:home).with(".chef", "bootstrap", "example.erb").and_return(nil)

          expect(File).to receive(:exists?).with(builtin_template_path).and_return(false)
          expect(File).to receive(:exists?).with(chef_config_dir_template_path).and_return(false)
          expect(File).to receive(:exists?).with(gem_files_template_path).and_return(true)
        end

        it "should load the template from Gem files" do
          expect(knife.find_template).to eq(gem_files_template_path)
        end
      end
    end
  end

  ["-t", "--bootstrap-template"].each do |t|
    context "when #{t} option is given in the command line" do
      it "sets the knife :bootstrap_template config" do
        knife.parse_options([t, "blahblah"])
        knife.merge_configs
        expect(knife.bootstrap_template).to eq("blahblah")
      end
    end
  end

  context "with run_list template" do
    let(:bootstrap_template) { File.expand_path(File.join(CHEF_SPEC_DATA, "bootstrap", "test.erb")) }

    it "should return an empty run_list" do
      expect(knife.render_template).to eq('{"run_list":[]}')
    end

    it "should have role[base] in the run_list" do
      knife.parse_options(["-r", "role[base]"])
      knife.merge_configs
      expect(knife.render_template).to eq('{"run_list":["role[base]"]}')
    end

    it "should have role[base] and recipe[cupcakes] in the run_list" do
      knife.parse_options(["-r", "role[base],recipe[cupcakes]"])
      knife.merge_configs
      expect(knife.render_template).to eq('{"run_list":["role[base]","recipe[cupcakes]"]}')
    end

    context "with bootstrap_attribute options" do
      let(:jsonfile) do
        file = Tempfile.new (["node", ".json"])
        File.open(file.path, "w") { |f| f.puts '{"foo":{"bar":"baz"}}' }
        file
      end

      it "should have foo => {bar => baz} in the first_boot from cli" do
        knife.parse_options(["-j", '{"foo":{"bar":"baz"}}'])
        knife.merge_configs
        expected_hash = FFI_Yajl::Parser.new.parse('{"foo":{"bar":"baz"},"run_list":[]}')
        actual_hash = FFI_Yajl::Parser.new.parse(knife.render_template)
        expect(actual_hash).to eq(expected_hash)
      end

      it "should have foo => {bar => baz} in the first_boot from file" do
        knife.parse_options(["--json-attribute-file", jsonfile.path])
        knife.merge_configs
        expected_hash = FFI_Yajl::Parser.new.parse('{"foo":{"bar":"baz"},"run_list":[]}')
        actual_hash = FFI_Yajl::Parser.new.parse(knife.render_template)
        expect(actual_hash).to eq(expected_hash)
        jsonfile.close
      end

      it "raises a Chef::Exceptions::BootstrapCommandInputError with the proper error message" do
        knife.parse_options(["-j", '{"foo":{"bar":"baz"}}'])
        knife.parse_options(["--json-attribute-file", jsonfile.path])
        knife.merge_configs
        allow(knife).to receive(:validate_name_args!)

        expect { knife.run }.to raise_error(Chef::Exceptions::BootstrapCommandInputError)
        jsonfile.close
      end
    end
  end

  context "with hints template" do
    let(:bootstrap_template) { File.expand_path(File.join(CHEF_SPEC_DATA, "bootstrap", "test-hints.erb")) }

    it "should create a hint file when told to" do
      knife.parse_options(["--hint", "openstack"])
      knife.merge_configs
      expect(knife.render_template).to match(/\/etc\/chef\/ohai\/hints\/openstack.json/)
    end

    it "should populate a hint file with JSON when given a file to read" do
      allow(::File).to receive(:read).and_return('{ "foo" : "bar" }')
      knife.parse_options(["--hint", "openstack=hints/openstack.json"])
      knife.merge_configs
      expect(knife.render_template).to match(/\{\"foo\":\"bar\"\}/)
    end
  end

  describe "specifying no_proxy with various entries" do
    subject(:knife) do
      k = described_class.new
      Chef::Config[:knife][:bootstrap_template] = template_file
      allow(k).to receive(:target_host).and_return target_host
      k.parse_options(options)
      k.merge_configs
      k
    end

    let(:options) { ["--bootstrap-no-proxy", setting, "-s", "foo"] }

    let(:template_file) { File.expand_path(File.join(CHEF_SPEC_DATA, "bootstrap", "no_proxy.erb")) }

    let(:rendered_template) do
      knife.render_template
    end

    context "via --bootstrap-no-proxy" do
      let(:setting) { "api.opscode.com" }

      it "renders the client.rb with a single FQDN no_proxy entry" do
        expect(rendered_template).to match(%r{.*no_proxy\s*"api.opscode.com".*})
      end
    end

    context "via --bootstrap-no-proxy multiple" do
      let(:setting) { "api.opscode.com,172.16.10.*" }

      it "renders the client.rb with comma-separated FQDN and wildcard IP address no_proxy entries" do
        expect(rendered_template).to match(%r{.*no_proxy\s*"api.opscode.com,172.16.10.\*".*})
      end
    end

    context "via --ssl-verify-mode none" do
      let(:options) { ["--node-ssl-verify-mode", "none"] }

      it "renders the client.rb with ssl_verify_mode set to :verify_none" do
        expect(rendered_template).to match(/ssl_verify_mode :verify_none/)
      end
    end

    context "via --node-ssl-verify-mode peer" do
      let(:options) { ["--node-ssl-verify-mode", "peer"] }

      it "renders the client.rb with ssl_verify_mode set to :verify_peer" do
        expect(rendered_template).to match(/ssl_verify_mode :verify_peer/)
      end
    end

    context "via --node-ssl-verify-mode all" do
      let(:options) { ["--node-ssl-verify-mode", "all"] }

      it "raises error" do
        expect { rendered_template }.to raise_error(RuntimeError)
      end
    end

    context "via --node-verify-api-cert" do
      let(:options) { ["--node-verify-api-cert"] }

      it "renders the client.rb with verify_api_cert set to true" do
        expect(rendered_template).to match(/verify_api_cert true/)
      end
    end

    context "via --no-node-verify-api-cert" do
      let(:options) { ["--no-node-verify-api-cert"] }

      it "renders the client.rb with verify_api_cert set to false" do
        expect(rendered_template).to match(/verify_api_cert false/)
      end
    end
  end

  describe "specifying the encrypted data bag secret key" do
    let(:secret) { "supersekret" }
    let(:options) { [] }
    let(:bootstrap_template) { File.expand_path(File.join(CHEF_SPEC_DATA, "bootstrap", "secret.erb")) }
    let(:rendered_template) do
      knife.parse_options(options)
      knife.merge_configs
      knife.render_template
    end

    it "creates a secret file" do
      expect(knife).to receive(:encryption_secret_provided_ignore_encrypt_flag?).and_return(true)
      expect(knife).to receive(:read_secret).and_return(secret)
      expect(rendered_template).to match(%r{#{secret}})
    end

    it "renders the client.rb with an encrypted_data_bag_secret entry" do
      expect(knife).to receive(:encryption_secret_provided_ignore_encrypt_flag?).and_return(true)
      expect(knife).to receive(:read_secret).and_return(secret)
      expect(rendered_template).to match(%r{encrypted_data_bag_secret\s*"/etc/chef/encrypted_data_bag_secret"})
    end

  end

  describe "when transferring trusted certificates" do
    let(:trusted_certs_dir) { Chef::Util::PathHelper.cleanpath(File.join(File.dirname(__FILE__), "../../data/trusted_certs")) }

    let(:rendered_template) do
      knife.merge_configs
      knife.render_template
    end

    before do
      Chef::Config[:trusted_certs_dir] = trusted_certs_dir
      allow(IO).to receive(:read).and_call_original
      allow(IO).to receive(:read).with(File.expand_path(Chef::Config[:validation_key])).and_return("")
    end

    def certificates
      Dir[File.join(trusted_certs_dir, "*.{crt,pem}")]
    end

    it "creates /etc/chef/trusted_certs" do
      expect(rendered_template).to match(%r{mkdir -p /etc/chef/trusted_certs})
    end

    it "copies the certificates in the directory" do
      certificates.each do |cert|
        expect(IO).to receive(:read).with(File.expand_path(cert))
      end

      certificates.each do |cert|
        expect(rendered_template).to match(%r{cat > /etc/chef/trusted_certs/#{File.basename(cert)} <<'EOP'})
      end
    end

    it "doesn't create /etc/chef/trusted_certs if :trusted_certs_dir is empty" do
      allow(Dir).to receive(:glob).and_call_original
      expect(Dir).to receive(:glob).with(File.join(trusted_certs_dir, "*.{crt,pem}")).and_return([])
      expect(rendered_template).not_to match(%r{mkdir -p /etc/chef/trusted_certs})
    end
  end

  context "when doing fips things" do
    let(:template_file) { File.expand_path(File.join(CHEF_SPEC_DATA, "bootstrap", "no_proxy.erb")) }
    let(:trusted_certs_dir) { Chef::Util::PathHelper.cleanpath(File.join(File.dirname(__FILE__), "../../data/trusted_certs")) }

    before do
      Chef::Config[:knife][:bootstrap_template] = template_file
    end

    let(:rendered_template) do
      knife.render_template
    end

    context "when knife is in fips mode" do
      before do
        Chef::Config[:fips] = true
      end

      it "renders 'fips true'" do
        Chef::Config[:fips] = true
        expect(rendered_template).to match("fips")
      end
    end

    context "when knife is not in fips mode" do
      before do
        # This is required because the chef-fips pipeline does
        # has a default value of true for fips
        Chef::Config[:fips] = false
      end

      it "does not render anything about fips" do
        expect(rendered_template).not_to match("fips")
      end
    end
  end

  describe "when transferring client.d" do

    let(:rendered_template) do
      knife.merge_configs
      knife.render_template
    end

    before do
      Chef::Config[:client_d_dir] = client_d_dir
    end

    context "when client_d_dir is nil" do
      let(:client_d_dir) { nil }

      it "does not create /etc/chef/client.d" do
        expect(rendered_template).not_to match(%r{mkdir -p /etc/chef/client\.d})
      end
    end

    context "when client_d_dir is set" do
      let(:client_d_dir) do
        Chef::Util::PathHelper.cleanpath(
        File.join(File.dirname(__FILE__), "../../data/client.d_00")) end

      it "creates /etc/chef/client.d" do
        expect(rendered_template).to match("mkdir -p /etc/chef/client\.d")
      end

      context "a flat directory structure" do
        it "escapes single-quotes" do
          expect(rendered_template).to match("cat > /etc/chef/client.d/02-strings.rb <<'EOP'")
          expect(rendered_template).to match("something '\\\\''/foo/bar'\\\\''")
        end

        it "creates a file 00-foo.rb" do
          expect(rendered_template).to match("cat > /etc/chef/client.d/00-foo.rb <<'EOP'")
          expect(rendered_template).to match("d6f9b976-289c-4149-baf7-81e6ffecf228")
        end
        it "creates a file bar" do
          expect(rendered_template).to match("cat > /etc/chef/client.d/bar <<'EOP'")
          expect(rendered_template).to match("1 / 0")
        end
      end

      context "a nested directory structure" do
        let(:client_d_dir) do
          Chef::Util::PathHelper.cleanpath(
          File.join(File.dirname(__FILE__), "../../data/client.d_01")) end
        it "creates a file foo/bar.rb" do
          expect(rendered_template).to match("cat > /etc/chef/client.d/foo/bar.rb <<'EOP'")
          expect(rendered_template).to match("1 / 0")
        end
      end
    end
  end



  describe "#connection_protocol" do
    let(:host_descriptor) { "example.com" }
    let(:config) { { } }
    let(:knife_connection_protocol) { nil }
    before do
      allow(knife).to receive(:config).and_return config
      allow(knife).to receive(:host_descriptor).and_return host_descriptor
      if knife_connection_protocol
        Chef::Config[:knife][:connection_protocol] = knife_connection_protocol
      end
    end

    context "when protocol is part of the host argument" do
      let(:host_descriptor) { "winrm://myhost" }

      it "returns the value provided by the host argument" do
        expect(knife.connection_protocol).to eq "winrm"
      end
    end

    context "when protocol is provided via the CLI flag" do
      let(:config) { { connection_protocol: "winrm" } }
      it "returns that value" do
        expect(knife.connection_protocol).to eq "winrm"
      end


    end
    context "when protocol is provided via the host argument and the CLI flag"  do
      let(:host_descriptor) { "ssh://example.com" }
      let(:config) { { connection_protocol: "winrm" } }

      it "returns the value provided by the host argument" do
        expect(knife.connection_protocol).to eq "ssh"
      end
    end

    context "when no explicit protocol is provided" do
      let(:config) { {} }
      let(:host_descriptor) { "example.com" }
      let(:knife_connection_protocol) { "winrm" }
      it "falls back to knife config" do
        expect(knife.connection_protocol).to eq "winrm"
      end
      context "and there is no knife bootstrap_protocol" do
        let(:knife_connection_protocol) { nil }
        it "falls back to 'ssh'" do
          expect(knife.connection_protocol).to eq "ssh"
        end
      end
    end

  end

  describe "#validate_protocol!" do
    let(:host_descriptor) { "example.com" }
    let(:config) { { } }
    let(:connection_protocol) { "ssh" }
    before do
      allow(knife).to receive(:config).and_return config
      allow(knife).to receive(:connection_protocol).and_return connection_protocol
      allow(knife).to receive(:host_descriptor).and_return host_descriptor
    end

    context "when protocol is provided both in the URL and via --protocol" do

      context "and they do not match" do
        let(:connection_protocol) { "ssh" }
        let(:config) { { connection_protocol: "winrm" } }
        it "outputs an error and exits" do
          expect(knife.ui).to receive(:error)
          expect{ knife.validate_protocol! }.to raise_error SystemExit
        end
      end

      context "and they do match" do
        let(:connection_protocol) { "winrm" }
        let(:config) { { connection_protocol: "winrm" } }
        it "returns true" do
          expect(knife.validate_protocol!).to eq true
        end
      end
    end

    context "and the protocol is supported" do

      Chef::Knife::Bootstrap::SUPPORTED_CONNECTION_PROTOCOLS.each do |proto|
        let(:connection_protocol) { proto }
        it "returns true for #{proto}" do
          expect(knife.validate_protocol!).to eq true
        end
      end
    end

    context "and the protocol is not supported" do
      let(:connection_protocol) { "invalid" }
      it "outputs an error and exits" do
        expect(knife.ui).to receive(:error).with(/Unsupported protocol '#{connection_protocol}'/)
        expect{ knife.validate_protocol! }.to raise_error SystemExit
      end
    end
  end

  describe "#validate_policy_options!" do

    context "when only policy_name is given" do

      let(:bootstrap_cli_options) { %w{ --policy-name my-app-server } }

      it "returns an error stating that policy_name and policy_group must be given together" do
        expect { knife.validate_policy_options! }.to raise_error(SystemExit)
        expect(stderr.string).to include("ERROR: --policy-name and --policy-group must be specified together")
      end

    end

    context "when only policy_group is given" do

      let(:bootstrap_cli_options) { %w{ --policy-group staging } }

      it "returns an error stating that policy_name and policy_group must be given together" do
        expect { knife.validate_policy_options! }.to raise_error(SystemExit)
        expect(stderr.string).to include("ERROR: --policy-name and --policy-group must be specified together")
      end

    end

    context "when both policy_name and policy_group are given, but run list is also given" do

      let(:bootstrap_cli_options) { %w{ --policy-name my-app --policy-group staging --run-list cookbook } }

      it "returns an error stating that policyfile and run_list are exclusive" do
        expect { knife.validate_policy_options! }.to raise_error(SystemExit)
        expect(stderr.string).to include("ERROR: Policyfile options and --run-list are exclusive")
      end

    end

    context "when policy_name and policy_group are given with no conflicting options" do

      let(:bootstrap_cli_options) { %w{ --policy-name my-app --policy-group staging } }

      it "passes options validation" do
        expect { knife.validate_policy_options! }.to_not raise_error
      end

      it "passes them into the bootstrap context" do
        expect(knife.bootstrap_context.first_boot).to have_key(:policy_name)
        expect(knife.bootstrap_context.first_boot).to have_key(:policy_group)
      end

      it "ensures that run_list is not set in the bootstrap context" do
        expect(knife.bootstrap_context.first_boot).to_not have_key(:run_list)
      end

    end

    # https://github.com/chef/chef/issues/4131
    # Arguably a bug in the plugin: it shouldn't be setting this to nil, but it
    # worked before, so make it work now.
    context "when a plugin sets the run list option to nil" do
      before do
        knife.config[:run_list] = nil
      end

      it "passes options validation" do
        expect { knife.validate_policy_options! }.to_not raise_error
      end
    end
  end

  # TODO - this is the only cli option we validate the _option_ itself -
  #        so we'll know if someone accidentally deletes or renames use_sudo_password
  #        Is this worht keeping?  If so, then it seems we should expand it
  #        to cover all options.
  context "validating use_sudo_password option" do
    it "use_sudo_password contains description and long params for help" do
      expect(knife.options).to(have_key(:use_sudo_password)) \
        && expect(knife.options[:use_sudo_password][:description].to_s).not_to(eq(""))\
        && expect(knife.options[:use_sudo_password][:long].to_s).not_to(eq(""))
    end
  end


  context "#connection_opts" do
    before :each do
      # TODO UNTESTED:
      # Chef::Config[:knife][:max_wait_seconds_until_ready] = 100
    end

    let(:expected_connection_opts) {
      { base_opts: true,
        ssh_identity_opts: true,
        ssh_opts: true,
        gateway_opts: true,
        host_verify_opts: true,
        sudo_opts: true,
        winrm_opts: true }
    }

    it "merges expected configurations" do
      expect(knife).to receive(:base_opts).and_return({ base_opts: true })
      expect(knife).to receive(:host_verify_opts).and_return({ host_verify_opts: true })
      expect(knife).to receive(:gateway_opts).and_return({ gateway_opts: true })
      expect(knife).to receive(:sudo_opts).and_return({ sudo_opts: true })
      expect(knife).to receive(:winrm_opts).and_return({ winrm_opts: true })
      expect(knife).to receive(:ssh_opts).and_return({ ssh_opts: true })
      expect(knife).to receive(:ssh_identity_opts).and_return({ ssh_identity_opts: true })
      expect(knife.connection_opts).to match expected_connection_opts
    end
  end

  context "#base_opts" do
    let(:connection_protocol) { nil }

    before do
      allow(knife).to receive(:connection_protocol).and_return connection_protocol
    end

    context "when determining knife config keys for user and port" do
      let(:connection_protocol) { "fake" }
      it "uses the protocol name to resolve the knife config keys" do
        allow(knife).to receive(:config_value).with(:max_wait)

        expect(knife).to receive(:config_value).with(:connection_port, :fake_port)
        expect(knife).to receive(:config_value).with(:connection_user, :fake_user)
        knife.base_opts
      end
    end

    context "for all protocols" do
      context "when password is provided" do
        before do
          knife.config[:connection_port] = 250
          knife.config[:connection_user] = "test"
          knife.config[:password] = "opscode"
        end

        let(:expected_opts) {
          {
            port: 250,
            user: "test",
            logger: Chef::Log,
            password: "opscode"
          }
        }
        it "generates the correct options" do
          expect(knife.base_opts).to eq expected_opts
        end

      end

      context "when password is not provided" do
        before do
          knife.config[:connection_port] = 250
          knife.config[:connection_user] = "test"
        end

        let(:expected_opts) {
          {
            port: 250,
            user: "test",
            logger: Chef::Log
          }
        }
        it "generates the correct options" do
          expect(knife.base_opts).to eq expected_opts
        end
      end
    end
  end

  context "#host_verify_opts" do
    let(:connection_protocol) { nil }
    before do
      allow(knife).to receive(:connection_protocol).and_return connection_protocol
    end

    context "for winrm" do
      let(:connection_protocol) { "winrm" }
      it "returns the expected configuration" do
        knife.config[:winrm_no_verify_cert] = true
        expect(knife.host_verify_opts).to eq( { self_signed: true } )
      end
      it "provides a correct default when no option given" do
        expect(knife.host_verify_opts).to eq( { self_signed: false } )
      end
    end

    context "for ssh" do
      let(:connection_protocol) { "ssh" }
      it "returns the expected configuration" do
        knife.config[:ssh_verify_host_key] = false
        expect(knife.host_verify_opts).to eq( { verify_host_key: false } )
      end
      it "provides a correct default when no option given" do
        expect(knife.host_verify_opts).to eq( { verify_host_key: true } )
      end
    end
  end

  context "#ssh_identity_opts" do
    let(:connection_protocol) { nil }
    before do
      allow(knife).to receive(:connection_protocol).and_return connection_protocol
    end

    context "for winrm" do
      let(:connection_protocol) { "winrm" }
      it "returns an empty hash" do
        expect(knife.ssh_identity_opts).to eq({})
      end
    end

    context "for ssh" do
      let(:connection_protocol) { "ssh" }
      context "when an identity file is specified" do
        before do
          knife.config[:ssh_identity_file] = "/identity.pem"
        end
        it "generates the expected configuration" do
          expect(knife.ssh_identity_opts).to eq({
              key_files: [ "/identity.pem" ],
              keys_only: true
            })
        end

        context "and a gateway identity file is also specified" do
          before do
            knife.config[:ssh_gateway_identity] = "/gateway.pem"
          end

          it "generates the expected configuration (both keys, keys_only true)" do
            expect(knife.ssh_identity_opts).to eq({
              key_files: [ "/identity.pem", "/gateway.pem" ],
              keys_only: true
            })
          end
        end
      end

      context "when no identity file is specified" do
        it "generates the expected configuration (no keys, keys_only false)" do
          expect(knife.ssh_identity_opts).to eq( {
            key_files: [ ],
            keys_only: false
          })
        end
        context "and a gateway identity file is specified" do
          before do
            knife.config[:ssh_gateway_identity] = "/gateway.pem"
          end
          it "generates the expected configuration (gateway key, keys_only false)" do
            expect(knife.ssh_identity_opts).to eq({
              key_files: [ "/gateway.pem" ],
              keys_only: false
            })
          end
        end
      end
    end
  end

  context "#gateway_opts" do
    let(:connection_protocol) { nil }
    before do
      allow(knife).to receive(:connection_protocol).and_return connection_protocol
    end

    context "for winrm" do
      let(:connection_protocol) { "winrm" }
      it "returns an empty hash" do
        expect(knife.gateway_opts).to eq({})
      end
    end

    context "for ssh" do
      let(:connection_protocol) { "ssh" }
      context "and ssh_gateway with hostname, user and port provided" do
        before do
          knife.config[:ssh_gateway] = "testuser@gateway:9021"
        end
        it "returns a proper bastion host config subset" do
          expect(knife.gateway_opts).to eq({
            bastion_user: "testuser",
            bastion_host: "gateway",
            bastion_port: 9021
          })
        end
      end
      context "and ssh_gateway with only hostname is given" do
        before do
          knife.config[:ssh_gateway] = "gateway"
        end
        it "returns a proper bastion host config subset" do
          expect(knife.gateway_opts).to eq({
            bastion_user: nil,
            bastion_host: "gateway",
            bastion_port: nil
          })
        end
      end
      context "and ssh_gateway with hostname and user is is given" do
        before do
          knife.config[:ssh_gateway] = "testuser@gateway"
        end
        it "returns a proper bastion host config subset" do
          expect(knife.gateway_opts).to eq({
            bastion_user: "testuser",
            bastion_host: "gateway",
            bastion_port: nil
          })
        end
      end

      context "and ssh_gateway with hostname and port is is given" do
        before do
          knife.config[:ssh_gateway] = "gateway:11234"
        end
        it "returns a proper bastion host config subset" do
          expect(knife.gateway_opts).to eq({
            bastion_user: nil,
            bastion_host: "gateway",
            bastion_port: 11234
          })
        end
      end

      context "and ssh_gateway is not provided" do
        it "returns an empty hash" do
          expect(knife.gateway_opts).to eq({})
        end
      end
    end
  end

  context "#sudo_opts" do
    let(:connection_protocol) { nil }
    before do
      allow(knife).to receive(:connection_protocol).and_return connection_protocol
    end

    context "for winrm" do
      let(:connection_protocol) { "winrm" }
      it "returns an empty hash" do
        expect(knife.sudo_opts).to eq({})
      end
    end

    context "for ssh" do
      let(:connection_protocol) { "ssh" }
      context "when use_sudo is set" do
        before do
          knife.config[:use_sudo] = true
        end

        it "returns a config that enables sudo" do
            expect(knife.sudo_opts).to eq( { sudo: true} )
        end

        context "when use_sudo_password is also set" do
          before do
            knife.config[:use_sudo_password] = true
            knife.config[:password] = "opscode"
          end
          it "includes :password value in a sudo-enabled configuration" do
            expect(knife.sudo_opts).to eq({
              sudo: true,
              sudo_password: "opscode"
            })
          end
        end

        context "when preserve_home is set" do
          before do
            knife.config[:preserve_home] = true
          end
          it "enables sudo with sudo_option to preserve home" do
            expect(knife.sudo_opts).to eq({
              sudo_options: "-H",
              sudo: true
            })
          end
        end

      end

      context "when use_sudo is not set" do
          before do
            knife.config[:use_sudo_password] = true
            knife.config[:preserve_home] = true
          end
          it "returns configuration for sudo off, ignoring other related options" do
            expect(knife.sudo_opts).to eq( { sudo: false} )
          end
        end
      end
  end

  context "#ssh_opts" do
    let(:connection_protocol) { nil }
    before do
      allow(knife).to receive(:connection_protocol).and_return connection_protocol
    end

    context "for ssh" do
      let(:connection_protocol) { "ssh" }
      context "when ssh_forward_agent has a value" do
        before do
          knife.config[:ssh_forward_agent] = true
        end
        it "returns a configuration hash with forward_agent set to true" do
          expect(knife.ssh_opts).to eq({ forward_agent: true })
        end
      end
      context "when ssh_forward_agent is not set" do
        it "returns a configuration hash with forward_agent set to false" do
          expect(knife.ssh_opts).to eq({ forward_agent: false })
        end
      end
    end

    context "for winrm" do
      let(:connection_protocol) { "winrm" }
      it "returns an empty has because ssh is not winrm" do
        expect(knife.ssh_opts).to eq({})
      end
    end

  end

  context "#winrm_opts" do
    let(:connection_protocol) { nil }
    before do
      allow(knife).to receive(:connection_protocol).and_return connection_protocol
    end

    context "for winrm" do
      let(:connection_protocol) { "winrm" }
      let(:expected) { {
        winrm_transport: "negotiate",
        winrm_basic_auth_only: false,
        ssl: false,
        ssl_peer_fingerprint: nil,
        operation_timeout: 30,
      }}

      it "generates a correct configuration hash with expected defaults" do
        expect(knife.winrm_opts).to eq expected
      end

      context "with ssl_peer_fingerprint" do
        let(:ssl_peer_fingerprint_expected) {
          expected.merge({ ssl_peer_fingerprint: "ABCD"})
        }

        before do
          knife.config[:winrm_ssl_peer_fingerprint] = "ABCD"
        end

        it "generates a correct options hash with ssl_peer_fingerprint from the config provided" do
          expect(knife.winrm_opts).to eq ssl_peer_fingerprint_expected
        end
      end

      context "with winrm_ssl" do
        let(:ssl_expected) {
          expected.merge({ ssl: true })
        }
        before do
          knife.config[:winrm_ssl] = true
        end

        it "generates a correct options hash with ssl from the config provided" do
          expect(knife.winrm_opts).to eq ssl_expected
        end
      end

      context "with winrm_auth_method" do
        let(:winrm_auth_method_expected) {
          expected.merge({ winrm_transport: "freeaccess" })
        }

        before do
          knife.config[:winrm_auth_method] = "freeaccess"
        end

        it "generates a correct options hash with winrm_transport from the config provided" do
          expect(knife.winrm_opts).to eq winrm_auth_method_expected
        end
      end

      context "with ca_trust_file" do
        let(:ca_trust_expected) {
          expected.merge({ ca_trust_file: "/trust.me"})
        }
        before do
          knife.config[:ca_trust_file] = "/trust.me"
        end

        it "generates a correct options hash with ca_trust_file from the config provided" do
          expect(knife.winrm_opts).to eq ca_trust_expected
        end
      end

      context "with kerberos auth" do
        let(:kerberos_expected) {
          expected.merge({
            kerberos_service: "testsvc",
            kerberos_realm: "TESTREALM",
            winrm_transport: "kerberos"
          })
        }

        before do
          knife.config[:winrm_auth_method] = "kerberos"
          knife.config[:kerberos_service] = "testsvc"
          knife.config[:kerberos_realm] = "TESTREALM"
        end

        it "generates a correct options hash containing kerberos auth configuration from the config provided" do
          expect(knife.winrm_opts).to eq kerberos_expected
        end
      end

      context "with winrm_basic_auth_only" do
        before do
          knife.config[:winrm_basic_auth_only] = true
        end
        let(:basic_auth_expected) {
          expected.merge( { winrm_basic_auth_only: true } )
        }
        it "generates a correct options hash containing winrm_basic_auth_only from the config provided" do
          expect(knife.winrm_opts).to eq basic_auth_expected
        end
      end
    end

    context "for ssh" do
      let(:connection_protocol) { "ssh" }
      it "returns an empty hash because ssh is not winrm" do
        expect(knife.winrm_opts).to eq({})
      end
    end
  end
  describe "#run" do
    before do
      allow(knife.client_builder).to receive(:client_path).and_return("/key.pem")
    end

    it "performs the steps we expect to run a bootstrap"  do
      expect(knife).to receive(:validate_name_args!).ordered
      expect(knife).to receive(:validate_protocol!).ordered
      expect(knife).to receive(:validate_first_boot_attributes!).ordered
      expect(knife).to receive(:validate_winrm_transport_opts!).ordered
      expect(knife).to receive(:validate_policy_options!).ordered

      expect(knife).to receive(:register_client).ordered
      expect(knife).to receive(:connect!).ordered
      expect(knife).to receive(:render_template).and_return "content"
      expect(knife).to receive(:upload_bootstrap).with("content").and_return "/remote/path.sh"
      expect(knife).to receive(:perform_bootstrap).with("/remote/path.sh")
      expect(target_host).to receive(:del_file) # Make sure cleanup happens

      knife.run

      # Post-run verify expected state changes (not many directly in #run)
      expect(knife.bootstrap_context.client_pem).to eq "/key.pem"
      expect($stdout.sync).to eq true
    end
  end

  describe "#register_client" do
    let(:vault_handler_mock) { double("ChefVaultHandler") }
    let(:client_builder_mock) { double("ClientBuilder") }
    let(:node_name) { nil }
    before do
      allow(knife).to receive(:chef_vault_handler).and_return vault_handler_mock
      allow(knife).to receive(:client_builder).and_return client_builder_mock
      knife.config[:chef_node_name] = node_name
    end

    shared_examples_for "creating the client locally" do
      context "when a valid node name is present" do
        let(:node_name) { "test" }
        before do
          allow(client_builder_mock).to receive(:client).and_return "client"
        end

        it "runs client_builder and vault_handler" do
          expect(client_builder_mock).to receive(:run)
          expect(vault_handler_mock).to receive(:run).with("client")
          knife.register_client
        end
      end

      context "when no valid node name is present" do
        let(:node_name) { nil }
        it "shows an error and exits" do
          expect(knife.ui).to receive(:error)
          expect{knife.register_client}.to raise_error(SystemExit)
        end
      end
    end
    context "when chef_vault_handler says we're using vault" do
      let(:vault_handler_mock) { double("ChefVaultHandler") }
      before do
        allow(vault_handler_mock).to receive(:doing_chef_vault?).and_return true
      end
      it_behaves_like "creating the client locally"
    end

    context "when an non-existant validation key is specified in chef config" do
      before do
        Chef::Config[:validation_key] = "/blah"
        allow(vault_handler_mock).to receive(:doing_chef_vault?).and_return false
        allow(File).to receive(:exist?).with("/blah").and_return false
      end
      it_behaves_like "creating the client locally"
    end

    context "when a valid validation key is given and we're doing old-style client creation" do
      before do
        Chef::Config[:validation_key] = "/blah"
        allow(File).to receive(:exist?).with("/blah").and_return true
        allow(vault_handler_mock).to receive(:doing_chef_vault?).and_return false
      end

      it "shows a message" do
        expect(knife.ui).to receive(:info)
        knife.register_client
      end
    end
  end

  describe "#perform_bootstrap" do
    let(:exit_status) { 0 }
    let(:result_mock) { double("result", exit_status: exit_status, stderr: "A message") }

    before do
      allow(target_host).to receive(:hostname).and_return "testhost"
    end
    it "runs the remote script and logs the output" do
      expect(knife.ui).to receive(:info).with(/Bootstrapping.*/)
      expect(knife).to receive(:bootstrap_command).
        with("/path.sh").
        and_return("sh /path.sh")
      expect(target_host).
        to receive(:run_command).
        with("sh /path.sh").
        and_yield("output here").
        and_return result_mock

      expect(knife.ui).to receive(:msg).with(/testhost/)
      knife.perform_bootstrap("/path.sh")
    end
    context "when the remote command fails" do
      let(:exit_status) { 1 }
      it "shows an error and exits" do
        expect(knife.ui).to receive(:info).with(/Bootstrapping.*/)
        expect(knife).to receive(:bootstrap_command).
          with("/path.sh").
          and_return("sh /path.sh")
        expect(target_host).to receive(:run_command).with("sh /path.sh").and_return result_mock
        expect{knife.perform_bootstrap("/path.sh")}.to raise_error(SystemExit)
      end
    end
  end


  describe "#connect!" do
    context "in the normal case" do
      it "connects using the connection_opts and notifies the operator of progress" do
        expect(knife.ui).to receive(:info).with(/Connecting to.*/)
        expect(knife).to receive(:connection_opts).and_return( { opts: "here" })
        expect(knife).to receive(:do_connect).with( { opts: "here" } )
        knife.connect!
      end
    end

    context "when a non-auth-failure occurs" do
      let(:expected_error) { RuntimeError.new }
      before do
        allow(knife).to receive(:do_connect).and_raise(expected_error)
      end
      it "re-raises the exception" do
        expect{knife.connect!}.to raise_error(expected_error)
      end
    end

    context "when an auth failure occurs" do
      let(:expected_error) {
        # TODO This is awkward and ugly. Requires some refactor of chef_core/error
        # to make it not so.  See comment in rescue block of connect! for details.
        e = RuntimeError.new
        interim = RuntimeError.new
        actual = Net::SSH::AuthenticationFailed.new
        allow(interim).to receive(:cause).and_return(actual)
        allow(e).to receive(:cause).and_return(interim)
        e
      }

      before do
        require 'net/ssh'
      end

      context "and password auth was used" do
        before do
          knife.config[:password] = "tryme"
        end

        it "re-raises the error so as not to resubmit the same failing password" do
          expect(knife).to receive(:do_connect).and_raise(expected_error)
          expect{knife.connect!}.to raise_error(expected_error)
        end
      end

      context "and password auth was not used" do
        before do
          knife.config[:password] = nil
          allow(target_host).to receive(:user).and_return "testuser"
        end

        it "warns, prompts for password, then reconnects with a password-enabled configuration using the new password" do
          expect(knife).to receive(:do_connect).and_raise(expected_error)
          expect(knife.ui).to receive(:warn).with(/Failed to auth.*/)
          expect(knife.ui).to receive(:ask).and_return("newpassword")
          expect(knife).to receive(:do_connect) do |opts|
             expect(opts[:password]).to eq "newpassword"
          end
          knife.connect!
        end
      end
    end
  end



  it "verifies that a server to bootstrap was given as a command line arg" do
    knife.name_args = nil
    expect { knife.run }.to raise_error(SystemExit)
    expect(stderr.string).to match(/ERROR:.+FQDN or ip/)
  end

  describe "#bootstrap_context" do
    context "under Windows" do
      let(:base_os) { :windows }
      it "creates a WindowsBootstrapContext" do
        require 'chef/knife/core/windows_bootstrap_context'
        expect(knife.bootstrap_context.class).to eq Chef::Knife::Core::WindowsBootstrapContext
      end
    end

    context "under linux" do
      let(:base_os) { :linux }
      it "creates a BootstrapContext" do
        require 'chef/knife/core/bootstrap_context'
        expect(knife.bootstrap_context.class).to eq Chef::Knife::Core::BootstrapContext
      end
    end
  end

  describe "#config_value" do
    before do
      knife.config[:test_key_a] = "a from cli"
      knife.config[:test_key_b] = "b from cli"
      Chef::Config[:knife][:test_key_a] = "a from Chef::Config"
      Chef::Config[:knife][:test_key_c] = "c from Chef::Config"
      Chef::Config[:knife][:alt_test_key_c] = "alt c from Chef::Config"
    end

    it "returns CLI value when key is only provided by the CLI" do
      expect(knife.config_value(:test_key_b)).to eq "b from cli"
    end

    it "returns CLI value when key is provided by CLI and Chef::Config" do
      expect(knife.config_value(:test_key_a)).to eq "a from cli"
    end

    it "returns Chef::Config value whent he key is only provided by Chef::Config" do
      expect(knife.config_value(:test_key_c)).to eq "c from Chef::Config"
    end

    it "returns the Chef::Config value from the alternate key when the CLI key is not set" do
      expect(knife.config_value(:test_key_c, :alt_test_key_c)).to eq "alt c from Chef::Config"
    end

    it "returns the default value when the key is not provided by CLI or Chef::Config" do
      expect(knife.config_value(:missing_key, :missing_key, "found")).to eq "found"
    end
  end

  describe "#upload_bootstrap" do
    before do
     allow(target_host).to receive(:temp_dir).and_return(temp_dir)
     allow(target_host).to receive(:normalize_path) { |a| a }
    end

    let(:content) { "bootstrap script content" }
    context "under Windows" do
      let(:base_os) { :windows }
      let(:temp_dir) { "C:/Temp/bootstrap" }
      it "creates a bat file in the temp dir provided by target_host, using given content" do
        expect(target_host).to receive(:save_as_remote_file).with(content, "C:/Temp/bootstrap/bootstrap.bat")
        expect(knife.upload_bootstrap(content)).to eq "C:/Temp/bootstrap/bootstrap.bat"
      end
    end

    context "under Linux" do
      let(:base_os) { :linux }
      let(:temp_dir) { "/tmp/bootstrap" }
      it "creates a 'sh file in the temp dir provided by target_host, using given content" do
        expect(target_host).to receive(:save_as_remote_file).with(content, "/tmp/bootstrap/bootstrap.sh")
        expect(knife.upload_bootstrap(content)).to eq "/tmp/bootstrap/bootstrap.sh"
      end
    end
  end

  describe "#bootstrap_command" do
    context "under Windows" do
      let(:base_os) { :windows }
      it "prefixes the command to run under cmd.exe" do
        expect(knife.bootstrap_command("autoexec.bat")).to eq "cmd.exe /C autoexec.bat"
      end

    end
    context "under Linux" do
      let(:base_os) { :linux }
      it "prefixes the command to run under sh" do
        expect(knife.bootstrap_command("bootstrap")).to eq "sh bootstrap"
      end
    end
  end


  describe "#default_bootstrap_template" do
    context "under Windows" do
      let(:base_os) { :windows }
      it "is windows-chef-client-msi" do
        expect(knife.default_bootstrap_template).to eq "windows-chef-client-msi"
      end

    end
    context "under Linux" do
      let(:base_os) { :linux }
      it "is chef-full" do
        expect(knife.default_bootstrap_template).to eq "chef-full"
      end
    end
  end
end


