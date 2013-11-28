module Bosh::Director
  module DeploymentPlan
    class Updater
      def initialize(job, event_log, resource_pools, assembler, deployment_plan)
        @job = job
        @logger = job.logger
        @event_log = event_log
        @resource_pools = resource_pools
        @assembler = assembler
        @deployment_plan = deployment_plan
      end

      def update
        event_log.begin_stage('Preparing DNS', 1)
        job.track_and_log('Binding DNS') do
          if Config.dns_enabled?
            assembler.bind_dns
          end
        end

        logger.info('Updating resource pools')
        resource_pools.update
        job.task_checkpoint

        logger.info('Binding instance VMs')
        assembler.bind_instance_vms

        event_log.begin_stage('Preparing configuration', 1)
        job.track_and_log('Binding configuration') do
          assembler.bind_configuration
        end

        logger.info('Deleting no longer needed VMs')
        assembler.delete_unneeded_vms

        logger.info('Deleting no longer needed instances')
        assembler.delete_unneeded_instances

        logger.info('Updating jobs')

        parents = []
        deployment_plan.jobs.each do |bosh_job|
          bosh_job.depends_on.each do |dep|
            if not parents.include? dep
              parents << dep
            end
          end
        end

        logger.info("All Parents : #{parents}")

        num_jobs = 0
        deployment_plan.jobs.each do |bosh_job|
          num_jobs = num_jobs + 1
        end

        ThreadPool.new(:max_threads => num_jobs).wrap do |pool|
          deployment_plan.jobs.each do |bosh_job|
            pool.process do
              loop do
                deps_met = true
                logger.info("Checking job dependencies for #{bosh_job.name}, #{bosh_job.depends_on}, #{parents}")
                bosh_job.depends_on.each do |dep|
                  if (parents.include? dep)
                    deps_met = false
                  end 
                end
                logger.info("Has job dependencies been met for #{bosh_job.name}: #{deps_met}")
                break if deps_met
                logger.info("Job #{bosh_job.name} waiting on dependent jobs to complete..")
                sleep(10)
              end
              job.task_checkpoint
              logger.info("Updating job: #{bosh_job.name}")
              JobUpdater.new(deployment_plan, bosh_job).update
              parents.delete(bosh_job.name)
              logger.info("Deleted #{bosh_job.name} from #{parents}")
            end
          end
        end

        logger.info('Refilling resource pools')
        resource_pools.refill
      end

      private

      attr_reader :job, :event_log, :resource_pools, :logger, :assembler, :deployment_plan
    end
  end
end
