module ProvisionEngine

    #
    # Abstraction to deserialize engine.conf config file
    #
    class Configuration < Hash

        DEFAULTS = {
            :one_xmlrpc => 'http://localhost:2633/RPC2',
            :oneflow_server => 'http://localhost:2474',
            :host => '127.0.0.1',
            :port => 1337,
            :capacity => {
                :max => {
                    :vcpu_mult => 2,
                    :memory_mult => 2
                },
                :default => {
                    :vcpu => 2,
                    :memory => 1024
                }
            },
            :log => {
                :level => 2,
                :system => 'file'
            }
        }

        FIXED = {
            :configuration_path => '/etc/provision-engine/engine.conf'
        }

        def initialize
            replace(DEFAULTS)

            begin
                merge!(YAML.load_file(FIXED[:configuration_path]))
            rescue StandardError => e
                STDERR.puts e
            end

            super
        end

    end

end
