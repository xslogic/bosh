# Copyright (c) 2009-2012 VMware, Inc.

module Bosh::Director
  module Api
    class ProblemManager

      def initialize(deployment_manager = DeploymentManager.new)
        @deployment_manager = deployment_manager
      end

      def perform_scan(user, deployment_name)
        deployment = @deployment_manager.find_by_name(deployment_name)

        JobQueue.new.enqueue(user, Jobs::CloudCheck::Scan, 'scan cloud', [deployment.name])
      end

      def get_problems(deployment_name)
        deployment = @deployment_manager.find_by_name(deployment_name)

        filters = {
          :deployment_id => deployment.id,
          :state => 'open'
        }

        Models::DeploymentProblem.filter(filters).order(:created_at).all
      end

      def apply_resolutions(user, deployment_name, resolutions)
        deployment = @deployment_manager.find_by_name(deployment_name)
        JobQueue.new.enqueue(user, Jobs::CloudCheck::ApplyResolutions, 'apply resolutions', [deployment.name, resolutions])
      end

      def scan_and_fix(user, deployment_name, jobs)
        deployment = @deployment_manager.find_by_name(deployment_name)

        JobQueue.new.enqueue(user, Jobs::CloudCheck::ScanAndFix, 'scan and fix', [deployment.name, jobs, Bosh::Director::Config.fix_stateful_nodes])
      end
    end
  end
end
