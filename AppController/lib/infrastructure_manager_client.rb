#!/usr/bin/ruby -w

# Imports within Ruby's standard libraries
require 'openssl'
require 'soap/rpc/driver'
require 'timeout'

require 'json'

# Imports for the AppController
$:.unshift File.join(File.dirname(__FILE__), "..")
require 'djinn'

# Imports for AppController libraries
$:.unshift File.join(File.dirname(__FILE__))
require 'helperfunctions'

class InfrastructureManagerClient
  # The port that the InfrastructureManager runs on, by default.
  SERVER_PORT = 17444

  # A constant that indicates that there should be no timeout on SOAP calls.
  NO_TIMEOUT = 100000

  # A constant that indicates the number of second to wait.
  SMALL_WAIT = 3

  # A constant that callers can use to indicate that SOAP calls should be
  # retried if they fail (e.g., if the connection was refused).
  RETRY_ON_FAIL = true

  # A constant that callers can use to indicate that SOAP calls should not
  # be retried if they fail.
  ABORT_ON_FAIL = false

  # The SOAP client that we use to communicate with the InfrastructureManager.
  attr_accessor :conn

  # The secret string that is used to authenticate this client with
  # InfrastructureManagers. It is initially generated by
  # appscale-run-instances and can be found on the machine that ran that tool,
  # or on any AppScale machine.
  attr_accessor :secret

  def initialize(secret)
    @ip = HelperFunctions.local_ip
    @secret = secret

    @conn = SOAP::RPC::Driver.new("https://#{@ip}:#{SERVER_PORT}")
    # We used self signed certificates. Don't verify them.
    @conn.options['protocol.http.ssl_config.verify_mode'] = nil
    @conn.add_method('get_queues_in_use', 'secret')
    @conn.add_method('run_instances', 'parameters', 'secret')
    @conn.add_method('describe_operation', 'parameters', 'secret')
    @conn.add_method('terminate_instances', 'parameters', 'secret')
    @conn.add_method('attach_disk', 'parameters', 'disk_name', 'instance_id',
      'secret')
    @conn.add_method('get_cpu_usage', 'secret')
    @conn.add_method('get_disk_usage', 'secret')
    @conn.add_method('get_memory_usage', 'secret')
    @conn.add_method('get_service_summary', 'secret')
    @conn.add_method('get_swap_usage', 'secret')
    @conn.add_method('get_loadavg', 'secret')
  end

  # Check the comments in AppController/lib/app_controller_client.rb.
  def make_call(time, retry_on_except, callr)
    begin
      Timeout.timeout(time) {
        begin
          yield if block_given?
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
          OpenSSL::SSL::SSLError, NotImplementedError, Errno::EPIPE,
          Errno::ECONNRESET, SOAP::EmptyResponseError, StandardError => e
          if retry_on_except
            Kernel.sleep(1)
            Djinn.log_debug("[#{callr}] exception in make_call to " \
              "#{@ip}:#{SERVER_PORT}. Exception class: #{e.class}. Retrying...")
            retry
          else
            trace = e.backtrace.join("\n")
            Djinn.log_warn('Exception encountered while talking to ' \
              "#{@ip}:#{SERVER_PORT}.\n#{trace}")
            raise FailedNodeException.new("Exception #{e.class}:#{e.message} encountered " \
              "while talking to #{@ip}:#{SERVER_PORT}.")
          end
        end
      }
    rescue Timeout::Error
      Djinn.log_warn("[#{callr}] SOAP call to #{@ip} timed out")
      raise FailedNodeException.new("Time out talking to #{@ip}:#{SERVER_PORT}")
    end
  end

  # Parses the credentials that AppControllers store and constructs a
  # Hash containing infrastructure-specific parameters.
  #
  # Args:
  #   options: A Hash that contains all of the credentials passed between
  #     AppControllers.
  # Returns:
  #   A Hash that contains only the parameters needed to interact with AWS,
  #   Eucalyptus, or GCE.
  def get_parameters_from_credentials(options)
    return {
      'credentials' => {
        # EC2 / Eucalyptus-specific credentials
        'EC2_ACCESS_KEY' => options['ec2_access_key'],
        'EC2_SECRET_KEY' => options['ec2_secret_key'],
        'EC2_URL' => options['ec2_url']
      },
      'project' => options['project'],  # GCE-specific
      'group' => options['group'],
      'image_id' => options['machine'],
      'infrastructure' => options['infrastructure'],
      'instance_type' => options['instance_type'],
      'keyname' => options['keyname'],
      'use_spot_instances' => options['use_spot_instances'],
      'max_spot_price' => options['max_spot_price'],
      'aws_vpc_id' => options['aws_vpc_id'],
      'aws_subnet_id' => options['aws_subnet_id'],
      'azure_subscription_id' => options['azure_subscription_id'],
      'azure_app_id' => options['azure_app_id'],
      'azure_app_secret_key' => options['azure_app_secret_key'],
      'azure_tenant_id' => options['azure_tenant_id'],
      'azure_resource_group' => options['azure_resource_group'],
      'azure_group_tag' => options['azure_group_tag'],
      'azure_storage_account' => options['azure_storage_account'],
      'autoscale_agent' => true
    }
  end

  def run_instances(parameters)
    obscured = parameters.dup
    obscured['credentials'] = HelperFunctions.obscure_options(obscured['credentials'])
    Djinn.log_debug('Calling run_instances with parameters ' +
      obscured.inspect.to_s)

    make_call(NO_TIMEOUT, RETRY_ON_FAIL, 'run_instances') {
      @conn.run_instances(parameters.to_json, @secret)
    }
  end

  def describe_operation(parameters)
    Djinn.log_debug('Calling describe_operation with parameters ' +
      parameters.inspect.to_s)

    make_call(NO_TIMEOUT, RETRY_ON_FAIL, 'describe_operation') {
      @conn.describe_operation(parameters.to_json, @secret)
    }
  end

  def terminate_instances(options, instance_ids)
    parameters = get_parameters_from_credentials(options)

    instance_ids = [instance_ids] if instance_ids.class != Array
    parameters['instance_ids'] = instance_ids
    parameters['region'] = options['region']
    parameters['IS_VERBOSE'] = options['verbose']
    parameters['zone'] = options['zone']

    terminate_result = make_call(NO_TIMEOUT, RETRY_ON_FAIL,
      'terminate_instances') {
      @conn.terminate_instances(parameters.to_json, @secret)
    }
    Djinn.log_debug("[IM] Terminate instances says [#{terminate_result}]")
    operation_id = terminate_result['operation_id']

    loop {
      describe_result = describe_operation('operation_id' => operation_id)
      Djinn.log_debug("[IM] Describe operation state is #{describe_result['state']}.")

      if describe_result['state'] == 'success'
        break
      elsif describe_result['state'] == 'failed'
        raise AppScaleException.new(describe_result['reason'])
      end
      Kernel.sleep(SMALL_WAIT)
    }
  end

  # Create new VMs.
  #
  # Args:
  #   num_vms: the number of VMs to create.
  #   options: a hash containing information needed by the agent
  #     (credentials etc ...).
  #   jobs: an Array containing the roles for each VM to be created.
  #   disks: an Array specifying the disks to be associated with the VMs
  #     (if any, it can be nil).
  #
  # Returns
  #   An Array containing the nodes information, suitable to be converted
  #   into Node.
  def spawn_vms(num_vms, options, jobs, disks)
    parameters = get_parameters_from_credentials(options)
    parameters['num_vms'] = num_vms.to_s
    parameters['cloud'] = 'cloud1'
    parameters['zone'] = options['zone']
    parameters['region'] = options['region']
    parameters['IS_VERBOSE'] = options['verbose']
    parameters['instance_type'] = options ['instance_type']

    run_result = run_instances(parameters)
    Djinn.log_debug("[IM] Run instances info says [#{run_result}]")
    operation_id = run_result['operation_id']

    vm_info = {}
    loop {
      describe_result = describe_operation('operation_id' => operation_id)
      Djinn.log_debug("[IM] Describe operation state is #{describe_result['state']} " \
        "and vm_info is #{describe_result['vm_info'].inspect}.")

      if describe_result['state'] == 'success'
        vm_info = describe_result['vm_info']
        break
      elsif describe_result['state'] == 'failed'
        raise AppScaleException.new(describe_result['reason'])
      end
      Kernel.sleep(SMALL_WAIT)
    }

    # ip:job:instance-id
    instances_created = []
    vm_info['public_ips'].each_index { |index|
      tmp_jobs = jobs[index]
      tmp_jobs = 'open' if jobs[index].nil?
      instances_created << {
        'public_ip' => vm_info['public_ips'][index],
        'private_ip' => vm_info['private_ips'][index],
        'jobs' => tmp_jobs,
        'instance_id' => vm_info['instance_ids'][index],
        'disk' => disks[index],
        'instance_type' => parameters['instance_type']
      }
    }

    instances_created
  end

  # Asks the InfrastructureManager to attach a persistent disk to this machine.
  #
  # Args:
  #   parameters: A Hash that contains the credentials necessary to interact
  #     with the underlying cloud infrastructure.
  #   disk_name: A String that names the persistent disk to attach to this
  #     machine.
  #   instance_id: A String that names this machine's instance id, needed to
  #     tell the InfrastructureManager which machine to attach the persistent
  #     disk to.
  # Returns:
  #   The location on the local filesystem where the persistent disk was
  #   attached to.
  def attach_disk(credentials, disk_name, instance_id)
    parameters = get_parameters_from_credentials(credentials)
    parameters['zone'] = credentials['zone'] if credentials['zone']
    parameters['region'] = credentials['region']
    parameters['autoscale_agent'] = true
    Djinn.log_debug('Calling attach_disk with parameters ' \
      "#{parameters.inspect}, with disk name #{disk_name} and instance id " +
      instance_id.to_s)

    make_call(NO_TIMEOUT, RETRY_ON_FAIL, 'attach_disk') {
      disk_info = @conn.attach_disk(parameters.to_json, disk_name, instance_id,
                                    @secret)
      Djinn.log_debug("Attach disk returned #{disk_info.inspect}")
      return disk_info['location']
    }
  end

  # Retrieves system monitoring statistics from the SystemManager.
  # Returns:
  #  A hash of the all the stats combined.
  def get_system_stats
    Djinn.log_debug('Calling SystemManager')

    cpu_usage = JSON.parse(@conn.get_cpu_usage(@secret))
    disk_usage = JSON.parse(@conn.get_disk_usage(@secret))
    memory_usage = JSON.parse(@conn.get_memory_usage(@secret))
    service_summary = JSON.parse(@conn.get_service_summary(@secret))
    swap_usage = JSON.parse(@conn.get_swap_usage(@secret))
    loadavg = JSON.parse(@conn.get_loadavg(@secret))

    all_stats = cpu_usage
    all_stats = all_stats.merge(disk_usage)
    all_stats = all_stats.merge(memory_usage)
    all_stats = all_stats.merge(swap_usage)
    all_stats = all_stats.merge(loadavg)

    # Service summary is a flat dictionary, while the rest contain nested
    # dictionaries.
    all_stats['services'] = service_summary

    JSON.dump(all_stats)
  end
end
