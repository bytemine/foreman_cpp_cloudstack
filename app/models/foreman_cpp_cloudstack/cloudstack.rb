###########################################################################
# Written by / Copyright (C) 2015 bytemine GmbH                           #
# sponsored by ennit AG                                                   #
# Author: Daniel Rauer                      E-Mail:    rauer@bytemine.net #
#                                                                         #
# http://www.bytemine.net/                                                #
###########################################################################

require 'uri'

module ForemanCPPCloudstack
    class Cloudstack < ComputeResource
        has_one :key_pair, :foreign_key => :compute_resource_id, :dependent => :destroy
        after_create :setup_key_pair
        after_destroy :destroy_key_pair
        delegate :flavors, :to => :client
        delegate :disk_offerings, :to => :client
        attr_accessor :zone, :hypervisor
        #alias_attribute :subnet_id, :network_ids

        validates :url, :user, :password, :presence => true

        # add additional params to the 'new' method
        def initialize(params)
            super
            if params
                attrs[:zone_id] = params[:zone]
                attrs[:hypervisor] = params[:hypervisor]
            end
        end

        def templates_isos
            list = Array.new
            templates = client.list_templates("self")["listtemplatesresponse"]["template"]
            if templates.any?
                list << {:id => "-1", :name => "--- Templates ---"}
                templates.each do |template|
                    list << {:id => template["id"], :name => template["name"]+" ("+template["zonename"]+")"}
                end
            end
            isos = client.list_isos["listisosresponse"]["iso"]
            if isos.any?
                list << {:id => "-1", :name => "--- ISOs ---"}
                isos.each do |iso|
                    list << {:id => iso["id"], :name => iso["name"]+" ("+iso["zonename"]+")"}
                end
            end
            list
        end

        def domains
            return [] if url.blank? or user.blank? or password.blank?
            domainsobj = client.list_domains

            domains_array = []
            zonesobj["listdomainsresponse"]["domain"].each do |domain|
                z =  domain["name"]
                domains_array.push(z)
            end
            logger.info(domainsobj)
            logger.info(domains_array)
            return domains_array
        end

        def zones
            return [] if url.blank? or user.blank? or password.blank?
            zonesobj = client.list_zones

            zones_array = []
            zonesobj["listzonesresponse"]["zone"].each do |zone|
                z =  {:name => zone["name"], :id => zone["id"]}
                zones_array.push(z)
            end
            return zones_array
        end

        # save the zone
        def set_zone=(zone_id)
            self.attrs[:zone_id] = zone_id
        end

        def get_zone
            self.attrs[:zone_id]
        end

        def hypervisors
            return [] if url.blank? or user.blank? or password.blank?
            hypervisorsobj = client.list_hypervisors

            hypervisors_array = []
            hypervisorsobj["listhypervisorsresponse"]["hypervisor"].each do |hypervisor|
                hypervisors_array.push(hypervisor["name"])
            end
            return hypervisors_array
        end

        def domain
            attrs[:domain]
        end

        def zone
            attrs[:zone]
        end

        def zone_id
            return client.list_zones["listzonesresponse"]["zone"][0]["id"]
        end

        def hypervisor
            attrs[:hypervisor]
        end

        def set_hypervisor=(hypervisor)
            self.attrs[:hypervisor] = hypervisor
        end

        def get_hypervisor
            self.attrs[:hypervisor]
        end

        def provided_attributes
            super.merge({ :ip => :ip_address, :mac => :mac_address })
        end

        def self.model_name
            ComputeResource.model_name
        end

        def image_param_name
            :image_ref
        end

        def capabilities
            [:image]
        end

        def networks
            fog_ntwrks = []
            networks_array = client.list_networks["listnetworksresponse"]["network"]
            networks_array.each do |network|
                ntwrk = Fog::Compute::Cloudstack::Address.new
                ntwrk.id = network["id"]
                ntwrk.network_id = network["name"]
                fog_ntwrks.push(ntwrk)
            end
            return fog_ntwrks
        end

        def test_connection options = {}
            client
            errors[:url].empty? and errors[:user].empty? and errors[:password].empty? and zones
        rescue Fog::Compute::Cloudstack::Error => e
            errors[:base] << e.message
        end

        def available_images
            client.images
        end

        def create_vm(args = {})
            args[:security_group_ids] = nil
            args[:network_ids] = [args[:network_ids]] if args[:network_ids]
            args[:network_ids] = [args[:subnet_id]] if args[:subnet_id]
            args[:network_ids] = nil

            args[:zone_id] = get_zone

            args[:display_name] = args[:name]
            # name has to be hostname without domain: no dots allowed
            name = args[:name].split(/\.(?=[\w])/).first || args[:name]
            args[:name] = name

            options = vm_instance_defaults.merge(args.to_hash.symbolize_keys)
            vm = client.servers.create options
            vm.wait_for { nics.present? }
            logger.warn "captured ipaddress"
            logger.warn vm.nics[0]["ipaddress"]
            logger.warn vm.inspect
            vm
        rescue => e
            message = JSON.parse(e.response.body)['badRequest']['message'] rescue (e.to_s)
            logger.warn "failed to create vm: #{message}"
            destroy_vm vm.id if vm
            raise message
        end

        def destroy_vm uuid
            find_vm_by_uuid(uuid).destroy
        rescue ActiveRecord::RecordNotFound
            # if the VM does not exists, we don't really care.
            true
        end

        def console(uuid)
            vm = find_vm_by_uuid(uuid)
            vm.console.body.merge({'timestamp' => Time.now.utc})
        end

        def associated_host(vm)
            Host.authorized(:view_hosts, Host).where(:ip => [vm.nics[0]["ipaddress"], vm.floating_ip_address, vm.private_ip_address]).first
        end

        def ip_address uuid
            vm = find_vm_by_uuid(uuid)
            vm.nics[0]["ipaddress"]
        end

        def flavor_name(flavor_ref)
            client.flavors.get(flavor_ref).try(:name)
        end

        def provider_friendly_name
            "Cloudstack"
        end

        private

        def client
            results =  /^(https|http):\/\/(\S+):(\d+)(\/\S+)/.match(url)
            scheme = results[1]
            path = results[4]
            host = results[2]
            port = results[3]

            @client = Fog::Compute.new(
                :provider => 'cloudstack',
                :cloudstack_api_key => user,
                :cloudstack_host => host,
                :cloudstack_port => port,
                :cloudstack_path => path,
                :cloudstack_scheme => scheme,
                :cloudstack_secret_access_key => password
            )
        end

        def setup_key_pair
            result = client.create_ssh_key_pair("foreman-#{id}#{Foreman.uuid}")
            private_key = result["createsshkeypairresponse"]["keypair"]["privatekey"]
            name = result["createsshkeypairresponse"]["keypair"]["name"]
            KeyPair.create! :name => name, :compute_resource_id => self.id, :secret => private_key
        rescue => e
            logger.warn "failed to generate key pair"
            destroy_key_pair
            raise
        end

        def destroy_key_pair
            return unless key_pair
            logger.info "removing CloudStack key #{key_pair.name}"
            result = client.delete_ssh_key_pair(key_pair.name)
            key.destroy if key
            key_pair.destroy
            true
        rescue => e
            logger.warn "failed to delete key pair from CloudStack, you might need to cleanup manually : #{e}"
        end

        def vm_instance_defaults
            super.merge(
                :key_name  => key_pair.name
            )
        end

    end
end
