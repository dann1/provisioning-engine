#!/usr/bin/env ruby

$LOAD_PATH << '/opt/provision-engine/' # install dir defined on install.sh

# Standard library
require 'json'
require 'yaml'
require 'base64'
require 'fileutils'
require 'syslog'
require 'securerandom'

# Gems
require 'sinatra'
require 'logger'
require 'json-schema'
require 'opennebula'
require 'opennebula/oneflow_client'

# Engine libraries
require 'log'
require 'configuration'
require 'client'
require 'runtime'

############################################################################
# Define API Helpers
############################################################################
RC = 'Response HTTP Return Code'.freeze
SR = 'Serverless Runtime'.freeze
SRD = "#{SR} definition".freeze
DENIED = 'Permission denied'.freeze
NO_AUTH = 'Failed to authenticate in OpenNebula'.freeze
SR_NOT_FOUND = "#{SR} not found".freeze

# Helper method to return JSON responses
def json_response(response_code, data)
    content_type :json
    status response_code
    data.to_json
end

def auth?
    auth_header = request.env['HTTP_AUTHORIZATION']

    if auth_header.nil?
        rc = 401
        message = 'Authentication required'

        settings.logger.error(message)
        halt rc, json_response(rc, message)
    end

    if auth_header.start_with?('Basic ')
        encoded_credentials = auth_header.split(' ')[1]
        username, password = Base64.decode64(encoded_credentials).split(':')
    else
        rc = 401
        message = 'Unsupported authentication scheme'

        settings.logger.error(message)
        halt rc, json_response(rc, message)
    end

    "#{username}:#{password}"
end

def body_valid?
    begin
        JSON.parse(request.body.read)
    rescue JSON::ParserError => e
        rc = 400
        settings.logger.error("Invalid JSON: #{e.message}")
        halt rc, json_response(rc, 'Invalid JSON data')
    end
end

def log_request(type)
    settings.logger.info("Received request to #{type}")
end

def log_response(level, code, data, message)
    if data.is_a?(String)
        body = data
    else
        body = data.to_json
    end

    settings.logger.info("#{RC}: #{code}")
    settings.logger.debug("Response Body: #{body}")
    settings.logger.send(level, message)
end

############################################################################
# API configuration
############################################################################

conf = ProvisionEngine::Configuration.new

configure do
    set :bind, conf[:host]
    set :port, conf[:port]
    set :logger, ProvisionEngine::Logger.new(conf[:log])
end

settings.logger.info "Using oned at #{conf[:one_xmlrpc]}"
settings.logger.info "Using oneflow at #{conf[:oneflow_server]}"

############################################################################
# Routes setup
############################################################################

# Log every HTTP Request received
before do
    if conf[:log] == 0
        call = "API Call: #{request.request_method} #{request.fullpath} #{request.body.read}"
        settings.logger.debug(call)
        request.body.rewind
    end
end

post '/serverless-runtimes' do
    log_request("Create a #{SR}")

    auth = auth?
    specification = body_valid?

    client = ProvisionEngine::CloudClient.new(conf, auth)

    response = ProvisionEngine::ServerlessRuntime.create(client, specification)
    rc = response[0]
    rb = response[1]

    case rc
    when 201
        log_response('info', rc, rb, "#{SR} created")
        json_response(rc, rb.to_sr)
    when 400
        log_response('error', rc, rb, "Invalid #{SRD}")
        halt rc, json_response(rc, rb)
    when 401
        log_response('error', rc, rb, NO_AUTH)
        halt rc, json_response(rc, rb)
    when 403
        log_response('error', rc, rb, DENIED)
        halt rc, json_response(rc, rb)
    when 422
        log_response('error', rc, rb, "Unprocessable #{SRD}")
        halt rc, json_response(rc, rb)
    when 504
        log_response('error', rc, rb, "Timeout when creating #{SR}")
        halt rc, json_response(rc, rb)
    else
        log_response('error', rc, rb, "Failed to create #{SR}")
        halt 500, json_response(500, rb)
    end
end

get '/serverless-runtimes/:id' do
    log_request("Retrieve a #{SR} information")

    auth = auth?

    client = ProvisionEngine::CloudClient.new(conf, auth)
    id = params[:id].to_i

    response = ProvisionEngine::ServerlessRuntime.get(client, id)
    rc = response[0]
    rb = response[1]

    case rc
    when 200
        log_response('info', rc, rb, SR)
        json_response(rc, rb.to_sr)
    when 401
        log_response('error', rc, rb, NO_AUTH)
        halt rc, json_response(rc, rb)
    when 403
        log_response('error', rc, rb, DENIED)
        halt rc, json_response(rc, rb)
    when 404
        log_response('error', rc, rb, SR_NOT_FOUND)
        halt rc, json_response(rc, rb)
    else
        log_response('error', rc, rb, "Failed to get #{SR}")
        halt 500, json_response(500, rb)
    end
end

put '/serverless-runtimes/:id' do
    log_request("Update a #{SR}")

    rc = 501
    message = "#{SR} update not implemented"

    settings.logger.error("#{SR} update not implemented")
    halt rc, json_response(rc, message)

    auth = auth?
    specification = body_valid?

    client = ProvisionEngine::CloudClient.new(conf, auth)

    id = params[:id].to_i

    ProvisionEngine::ServerlessRuntime.update(client, id, specification)
end

delete '/serverless-runtimes/:id' do
    log_request("Delete a #{SR}")

    auth = auth?

    id = params[:id].to_i

    client = ProvisionEngine::CloudClient.new(conf, auth)

    # Obtain serverless runtime

    response = ProvisionEngine::ServerlessRuntime.get(client, id)
    rc = response[0]
    rb = response[1]

    case rc
    when 200
        runtime = rb

        response = runtime.delete
        rc = response[0]
        rb = response[1]

        case rc
        when 204
            log_response('info', rc, rb, "#{SR} deleted")
            json_response(rc, rb)
        when 403
            log_response('error', rc, rb, DENIED)
            halt rc, json_response(rc, rb)
        else
            log_response('error', rc, rb, "Failed to delete #{SR}")
            halt 500, json_response(500, rb)
        end
    when 401
        log_response('error', rc, rb, NO_AUTH)
        halt rc, json_response(rc, rb)
    when 403
        log_response('error', rc, rb, DENIED)
        halt rc, json_response(rc, rb)
    when 404
        log_response('error', rc, rb, SR_NOT_FOUND)
        halt rc, json_response(rc, rb)
    else
        log_response('error', rc, rb, "Failed to delete #{SR}")
        halt 500, json_response(500, rb)
    end
end
