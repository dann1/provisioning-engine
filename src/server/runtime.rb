module ProvisionEngine

    #
    # Document that references a service running functions specified by a client
    #
    class ServerlessRuntime < OpenNebula::DocumentJSON

        SR = 'Serverless Runtime'.freeze
        DOCUMENT_TYPE = 1337

        SCHEMA_SPECIFICATION = {
            :type => 'object',
            :properties => {
                :SERVERLESS_RUNTIME => {
                    :type => 'object',
                :properties => {
                    :NAME => {
                        :type => 'string'
                    },
                    :ID => {
                        :type => 'integer'
                    },
                    :SERVICE_ID => {
                        :type => 'integer'
                    },
                    :FAAS => {
                        :type => 'object',
                    :properties => {
                        :CPU => {
                            :type => 'number'
                        },
                        :MEMORY => {
                            :type => 'integer'
                        },
                        :DISK_SIZE => {
                            :type => 'integer'
                        },
                        :FLAVOUR => {
                            :type => 'string'
                        }
                    },
                    :required => ['FLAVOUR']
                    },
                    :DAAS => {
                        'oneOf' => [
                            {
                                :type => 'object',
                              :properties => {
                                  :CPU => {
                                      :type => 'number'
                                  },
                                :MEMORY => {
                                    :type => 'integer'
                                },
                                :DISK_SIZE => {
                                    :type => 'integer'
                                },
                                :FLAVOUR => {
                                    :type => 'string'
                                }
                              },
                              :required => ['FLAVOUR']
                            },
                            {
                                :type =>  'null'
                            }
                        ]
                    },
                    :SCHEDULING => {
                        :type => 'object',
                    :properties => {
                        :POLICY => {
                            :type => 'string'
                        },
                        :REQUIREMENTS => {
                            :type => 'string'
                        }
                    }
                    },
                    :DEVICE_INFO => {
                        :type => 'object',
                    :properties => {
                        :LATENCY_TO_PE => {
                            :type => 'integer'
                        },
                        :GEOGRAPHIC_LOCATION => {
                            :type => 'string'
                        }
                    }
                    }
                },
                :required => ['FAAS']
                }
            }
        }

        attr_accessor :cclient, :body

        def self.create(client, specification)
            response = ServerlessRuntime.validate(specification)
            return [400, response[1]] unless response[0]

            specification = specification['SERVERLESS_RUNTIME']

            client.logger.info("Creating oneflow Service for #{SR}")

            response = ServerlessRuntime.to_service(client, specification)
            rc = response[0]
            rb = response[1]

            return [rc, rb] if rc != 201

            service_id = rb['DOCUMENT']['ID']

            client.logger.info("#{SR} Service #{service_id} created")

            ServerlessRuntime.service_sync(client, specification, service_id)

            client.logger.info("Allocating #{SR} Document")
            client.logger.debug(specification)

            xml = ServerlessRuntime.build_xml
            runtime = ServerlessRuntime.new(xml, client.client_oned)
            response = runtime.allocate(specification)

            if OpenNebula.is_error?(response)
                return [ProvisionEngine::CloudClient.map_error_oned(response.errno),
                        response.message]
            end

            client.logger.info("Created #{SR} Document")

            runtime.info

            [201, runtime]
        end

        def self.get(client, id)
            runtime = ServerlessRuntime.new_with_id(id, client.client_oned)
            runtime.info

            runtime.cclient = client

            return [404, 'Document not found'] if runtime.name.nil?

            runtime.load_body
            service_id = runtime.body['SERVICE_ID']

            ServerlessRuntime.service_sync(client, runtime.body, service_id)
            runtime.update

            [200, runtime]
        end

        def delete
            cclient.logger.info("Deleting #{SR} Service")

            document = JSON.parse(to_json)

            service_id = document['DOCUMENT']['TEMPLATE']['BODY']['SERVICE_ID']
            response = cclient.service_delete(service_id)
            rc = response[0]

            if rc == 404
                cclient.logger.warning("Cannot find #{SR} Service")
            elsif rc != 204
                rb = response[1]
                return [rc, rb]
            end

            cclient.logger.info("Deleting #{SR} Document")
            response = super()

            if OpenNebula.is_error?(response)
                return [ProvisionEngine::CloudClient.map_error_oned(response.errno),
                        response.message]
            end

            cclient.logger.info("#{SR} Document deleted")

            [204, '']
        end

        #####################
        # Inherited Functions
        #####################

        # Service must have been created prior to allocating the document
        def allocate(specification)
            specification['registration_time'] = Integer(Time.now)

            if specification['NAME']
                name = specification['NAME']
            else
                name = "#{ServerlessRuntime.tuple(specification)}_#{SecureRandom.uuid}"
            end

            super(specification.to_json, name)
        end

        #################
        # Helpers
        #################

        #
        # Translates the Serverless Runtime document to the SCHEMA
        #
        # @return [Hash] Serverless Runtime definition
        #
        def to_sr
            load_body if @body.nil?

            runtime = {
                :SERVERLESS_RUNTIME => {
                    :NAME => name,
                    :ID => id
                }
            }
            rsr = runtime[:SERVERLESS_RUNTIME]

            rsr.merge!(@body)
            rsr.delete('registration_time')

            runtime
        end

        #
        # Updates Serverless Runtime Document specification based on the underlying elements state
        #
        # @param [CloudClient] client OpenNebula interface
        # @param [Hash] runtime_definition Serverless Runtime definition to be updated
        # @param [Integer] service_id OneFlow service ID mapped to the Serverless Runtime
        # @param [Integer] timeout How long to wait for Role VMs to be created
        #
        def self.service_sync(client, runtime_definition, service_id, timeout = 30)
            1.upto(timeout) do |t|
                sleep 1

                if t == 30
                    msg = "OpenNebula did not create VMs for the #{SR} service after #{t} seconds"
                    return [504, msg]
                end

                response = client.service_get(service_id)
                rc = response[0]
                rb = response[1]

                return [rc, rb] if rc != 200

                service = rb

                service_template = service['DOCUMENT']['TEMPLATE']['BODY']
                roles = service_template['roles']

                begin
                    roles[0]['nodes'][0]['vm_info']['VM']
                rescue NoMethodError # will fail if service VM information is missing
                    client.logger.debug("Waiting #{t} seconds for service VMs")

                    next
                end

                client.logger.debug(service)

                runtime_definition['SERVICE_ID'] = service['DOCUMENT']['ID'].to_i
                runtime_definition['FAAS'].merge!(xaas_template(client, roles[0]))
                runtime_definition['DAAS'].merge!(xaas_template(client, roles[1])) if roles[1]

                break
            end
        end

        #
        # Validates the Serverless Runtime specification using the distributed schema
        #
        # @param [Hash] specification a valid runtime specification parsed to a Hash
        #
        # @return [Array] [true,''] or [false, 'reason']
        #
        def self.validate(specification)
            begin
                JSON::Validator.validate!(SCHEMA_SPECIFICATION, specification)
                [true, '']
            rescue JSON::Schema::ValidationError => e
                [false, "Invalid #{SR} specification: #{e.message}"]
            end
        end

        #
        # Create oneflow service based on Serverless Runtime specification
        #
        # @param [CloudClient] OpenNebula interface
        # @param [Hash] specification Serverless Runtime specification
        #
        # @return [Array] Response Code and Body of the operation
        #
        def self.to_service(client, specification)
            response = client.service_template_pool_get
            rc = response[0]

            return response if rc != 200

            service_templates = response[1]['DOCUMENT_POOL']['DOCUMENT']

            tuple = ServerlessRuntime.tuple(specification)

            service_templates.each do |service_template|
                next unless service_template['TEMPLATE']['BODY']['name'] == tuple

                id = service_template['ID']

                return client.service_template_instantiate(id)
            end

            msg = "Cannot find a valid service template for the specified flavours: #{tuple}\n"
            msg << "FaaS -> #{specification['FAAS']}"
            msg << "DaaS -> #{specification['DAAS']}" if specification['DAAS']

            return [422, msg]
        end

        def self.tuple(specification)
            tuple = specification['FAAS']['FLAVOUR']
            tuple = "#{tuple}-#{specification['DAAS']['FLAVOUR']}" if specification['DAAS']
            tuple
        end

        #
        # Creates a runtime function hash for the Serverless Runtime document
        #
        # @param [CloudClient] OpenNebula interface
        # @param [Hash] role oneflow service role information
        #
        # @return [Hash] Function hash
        #
        def self.xaas_template(client, role)
            xaas_template = {}

            vm_info = role['nodes'][0]['vm_info']['VM']
            vm_id = vm_info['ID'].to_i

            response = client.vm_get(vm_id)
            rc = response[0]
            rb = response[1]

            return response unless rc == 200

            vm = rb

            # rubocop:disable Style/StringLiterals rubocop complains but is needed for ID=0
            xaas_template['VM_ID'] = vm_id
            xaas_template['STATE'] = vm.state_str
            xaas_template['ENDPOINT'] = vm["//TEMPLATE/NIC[NIC_ID=\"0\"]/IP"]

            xaas_template['CPU'] = vm['//TEMPLATE/CPU'].to_f
            xaas_template['VCPU'] = vm['//TEMPLATE/VCPU'].to_i
            xaas_template['MEMORY'] = vm['//TEMPLATE/MEMORY'].to_i
            xaas_template['DISK_SIZE'] = vm["//TEMPLATE/DISK[DISK_ID=\"0\"]/SIZE"].to_i
            # rubocop:enable Style/StringLiterals

            xaas_template
        end

    end

end
