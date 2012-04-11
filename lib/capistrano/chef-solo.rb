require 'capistrano'
require 'chef/knife'
require 'chef/data_bag_item'
require 'chef/search/query'

module Capistrano::Chef
  # Set up chef configuration
  def self.configure_chef
    knife = Chef::Knife.new
    # If you don't do this it gets thrown into debug mode
    knife.config = { :verbosity => 1 }
    knife.configure_chef
    
    ::Chef::Config[:solo] = true
    ::Chef::Config.data_bag_path "./data_bags"
    ::Chef::Config.role_path     "./roles"
    
  end

  # Do a search on the Chef server and return an attary of the requested
  # matching attributes
  # def self.search_chef_nodes(query = '*:*', options = {})
  #   # TODO: This can only get a node's top-level attributes. Make it get nested
  #   # ones.
  #   attr = options.delete(:attribute) || :ipaddress
  #   Chef::Search::Query.new.search(:node, query)[0].map {|n| n[attr] }
  # end
  # 
  # def self.get_apps_data_bag_item(id)
  #   Chef::DataBagItem.load("apps", id).raw_data
  # end

  # Load into Capistrano
  def self.load_into(configuration)
    self.configure_chef
    configuration.set :capistrano_chef, self
    configuration.load do
      # def chef_role(name, query = '*:*', options = {})
      #   role name, *capistrano_chef.search_chef_nodes(query), options
      # end
      # def set_from_data_bag
      #   raise ':application must be set' if fetch(:application).nil?
      #   capistrano_chef.get_apps_data_bag_item(application).each do |k, v|
      #     set k, v
      #   end
      # end
      
      set :application, nil
      set :environment, nil
      
      # Automatically loads all applications 
      def _register_chef_applications(options={})
        apps = ::Chef::DataBag.load("apps")
        if apps.length == 1
          # If there is only one application, it gets loaded immediately. We go ahead and create the 
          # task for it, but it does get loaded without being asked to.
          app_name = apps.first.last['id'] || apps.first.first
          namespace :app do
            desc "Apply to the #{app_name} application"
            task app_name.to_sym do
              load_application app_name
            end
          end
          load_application app_name
          # puts "Registering the only application: #{app_name}"
        else 
          apps.each do |name, data|
            # Define a root task for each application
            app_name = data['id'] || name
            # puts "Registering an application: #{app_name}"
            namespace :app do
              desc "Apply to the #{app_name} application"
              task app_name.to_sym do
                load_application app_name
              end
            end
          end
        end
      end
      def load_application(name)
        raise "Really, you should only ever load an application once in a cap call." if application
        set :application, name
        bag = ::Chef::DataBagItem.load("apps", name)
        
        # Set primary params from the app
        set_param_from_app :deploy_to
        set_param_from_app :deploy_via, nil, :remote_cache
        set_param_from_app :user, :owner
        set_param_from_app :runner, %w{user owner}
        set_param_from_app :repository, :repo
        set_param_from_app :scm

        # How to authenticate deployment. If we have a deploy key in the app, we can simply 
        # pull in our deploy key specs, and carry on without using a password at all.
        # But if we don't have one, our second guess is to forward local agent to the server
        # and expect that there's a key between local machine and scm server. 
        if false && key = (bag.keys & %w{deploy_key deploy_ssh_key scm_key})
          puts "Found a deploy key. Now we should have a deploy key wrapper"
          set :use_sudo, false
        else
          # Assumes we'll use forwarded agents for scm repo authentication. No need to attach 
          set :scm_verbose, true
          set :scm_username, `whoami`
          ssh_options[:forward_agent] = true
          ssh_options[:paranoid] = false
        end
        
        assign_roles
      end
      
      def set_param_from_app(param_name, aliases=[], default=nil)
        bag = ::Chef::DataBagItem.load("apps", application)
        key = ((Array(param_name) + Array(aliases)).collect { |k| k.to_s rescue k } & bag.keys).first
        val = bag[key.to_s]
        val = default if val.nil?
        set param_name.to_sym, val unless val.nil?
      end
      
      # Loads all nodes
      # def _register_chef_nodes(options={})
      #   get_nodes.each do |chef_node|
      #     puts "Registering a node: #{chef_node.name}"
      #     namespace :chef_node do
      #       desc "Apply to the #{chef_node.name} node"
      #       task chef_node.name do
      #         load_chef_node chef_node.name
      #         autoset_environment
      #       end
      #     end
      #   end
      # end
      
      # Loads all environments
      def _register_chef_environments(options={})
        
        list = Dir.glob("environments/*.json").collect do |f|
          item = JSON.parse(IO.read(f))
          item['name'] 
        end
        
        list += Dir.glob("environments/*.rb").collect do |f|
          r = ::Chef::Role.new
          r.from_file(f)
          r.name
        end
        
        list += Dir.glob("roles/*.json").collect do |f|
          item = JSON.parse(IO.read(f))
          item['type'] if item['type'] == "environment"
        end

        list += Dir.glob("roles/*.rb").collect do |f|
          r = ::Chef::Role.new
          r.from_file(f)
          r.name if r.default_attributes.has_key?(:chef_environment)
        end
        
        list.compact.uniq.each do |env_name|
          # puts "Registering an environment: #{env_name}"
          
          # Sets the environment tasks
          desc "Apply to the #{env_name} environment"
          task env_name.to_sym do
            set_environment env_name
          end
        end
      end

      task :chef_report do
        _chef_report
      end
      def _chef_report
        puts "\nChef Report:"
        puts "  application: #{application}"
        puts "  environment: #{environment}"
        # puts "  node:        #{node}"
        
        
        puts "  Cap roles: "
        roles.each do |role_name, r|
          puts "    #{role_name}: #{r.servers.join(', ')}"
        end
        
        puts "  Necessary deployment params:"
        %w{deploy_to user runner scm repository branch rails_env deploy_via use_sudo}.each do |attrib|
          
          puts "    #{attrib}: #{self[attrib.to_sym] if exists?(attrib)}" 
        end
        # puts "    deploy_to:   #{deploy_to}"
        # puts "    runner:      #{runner}"
        # puts "    scm:         #{scm}"
        # puts "    repository:  #{repository}"
        # puts "    branch:      #{branch}"

        puts ""
        
      end

      def set_environment(env_name)
        # set :environment, get_node_by_name(node).chef_environment if node
        set :environment, env_name
        set :rails_env, env_name

        # Set some environment specific params
        bag = ::Chef::DataBagItem.load("apps", application)
        set :branch, bag['revision'][environment]

        assign_roles
      end
      
      def assign_roles
        return unless environment && application
        bag = ::Chef::DataBagItem.load("apps", application)
        # Set db roles
        db_roles = %w{database_master_role database_slave_role database_role}
        chef_db_roles(bag.values_at(*db_roles).flatten.compact)
        # Set web roles
        web_roles = %w{web_master_role web_slave_role web_role}
        chef_web_roles(bag.values_at(*db_roles).flatten.compact)
        # Set app roles
        app_roles = %w{app_master_role app_slave_role app_role}
        chef_app_roles(bag.values_at(*db_roles).flatten.compact)

        # Report whats going to be used.
        _chef_report
      end
      

      
      def get_nodes
        nodes ||= Dir.glob("nodes/*.json").collect{ |f|
          ::Chef::Node.json_create(JSON.parse(IO.read(f)))
        } + Dir.glob("nodes/*.rb").collect{ |f|
          n = ::Chef::Node.new
          n.from_file f
          n
        }
        set :nodes, nodes
        return nodes
      end
      
      def get_node_by_name(name)
        puts "find by name #{name}"
        get_nodes.select do |node|
          name == node.name
        end.first
      end
      
      def find_nodes(options={})
        # puts "Find nodes. #{options}"
        get_nodes.select do |node|
          valid = true
          
          if options.has_key?(:name)
            valid = valid && node.name == options[:name]
          end
          if options.has_key?(:role)
            valid = valid && node.role?(options[:role])
          end
          if options.has_key?(:environment)
            valid = valid && node.chef_environment == options[:environment]
          end
          if options.has_key?(:recipe)
            valid = valid && node.recipe?(options[:recipe])
          end
          
          valid
        end
      end
      
      # def get_proper_node
      #   raise "You must first specify an application and and an environment" unless application && environment
      #   get_nodes.each do |node|
      #     
      #     puts "...."
      #     puts node.name
      #     puts node.run_list
      #     puts node.chef_environment
      #     
      #     
      #     
      #   end
      # end
      
      def chef_app_roles(chef_role_names)
        assign_capistrano_roles(:app, chef_role_names)
      end
      def chef_web_roles(chef_role_names)
        assign_capistrano_roles(:web, chef_role_names)
      end
      def chef_db_roles(chef_role_names)
        assign_capistrano_roles(:db, chef_role_names)
      end
      def assign_capistrano_roles(capistrano_role, chef_role_names)
        Array(chef_role_names).each do |name|
          hosts = find_nodes(:environment => environment, :role => name).collect do |node|
            key = (%w{domain ip_address ip ipaddress} & node.keys).first
            node[key] || node.name
          end
          role capistrano_role.to_sym, *hosts
        end
      end
      
      
      # before "deploy:cold", "doublecheck_param_exist_from_chef"
      # 
      # task :doublecheck_param_exist_from_chef do
      #   %w{deploy_via}.each do |attrib|
      #     raise "The param \"#{attrib}\" is required for deployment." unless exists?(attrib)
      #     puts " >> #{attrib}: #{self[attrib.to_sym] if exists?(attrib)}" 
      #   end
      # 
      # end
      
        
      _register_chef_applications
      _register_chef_environments
      
    end
  end
end

if Capistrano::Configuration.instance
  Capistrano::Chef.load_into(Capistrano::Configuration.instance)
end
