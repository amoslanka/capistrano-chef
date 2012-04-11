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
      set :node, nil
      
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
          puts "Registering the only application: #{app_name}"
        else 
          apps.each do |name, data|
            # Define a root task for each application
            app_name = data['id'] || name
            puts "Registering an application: #{app_name}"
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
        set :application, name
        ::Chef::DataBagItem.load("apps", name).each do |k, v|
          set k, v
        end
      end
      
      # Loads all nodes
      def _register_chef_nodes(options={})
        get_nodes.each do |chef_node|
          puts "Registering a node: #{chef_node.name}"
          namespace :chef_node do
            desc "Apply to the #{chef_node.name} node"
            task chef_node.name do
              load_chef_node chef_node.name
              autoset_environment
            end
          end
        end
      end
      
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
          puts "Registering an environment: #{env_name}"
          
          # Sets the environment tasks
          desc "Apply to the #{env_name} environment"
          task env_name.to_sym do
            set :environment, env_name
          end
        end
      end

      def _chef_report
        task :chef_report do
          puts "\nChef Report:"
          puts "  application: #{application}"
          puts "  environment: #{environment}"
          puts "  node:        #{node}"
          
          puts "  deploy_to:   #{deploy_to}"
          
          puts ""
        end
      end
      
      
      # before 'deploy', 'chef:crossref'

      def load_chef_node(name)
        set :node, name
        # Try to auto populate some more variables, such as ip address.
        
      end

      def autoset_environment
        set :environment, get_node_by_name(node).chef_environment if node
      end
      def autoset_node
        return unless application && environment
        
        get_nodes.each do |node|
          next if node.chef_environment != environment
          
          
          puts "...."
          puts node.name
          puts node.run_list
          puts node.chef_environment
          
          
        end
        
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
        
      _register_chef_applications
      _register_chef_environments
      _register_chef_nodes
      _chef_report




      def chef_db_roles(names)
        names = [names] unless names.is_a?(Array)
        
        
        
      end


      
    end
  end
end

if Capistrano::Configuration.instance
  Capistrano::Chef.load_into(Capistrano::Configuration.instance)
end
