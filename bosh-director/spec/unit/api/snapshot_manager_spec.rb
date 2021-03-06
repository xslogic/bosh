require 'spec_helper'

module Bosh::Director
  describe Api::SnapshotManager do
    let(:cloud) { instance_double('Bosh::Cloud') }
    let(:user) { Models::User.make }
    let(:time) { Time.now.to_s }

    let(:deployment) { Models::Deployment.make(name: 'deployment') }

    before do
      Config.stub(cloud: cloud)

      # instance 1: one disk with two snapshots
      vm = Models::Vm.make(cid: 'vm-cid0', agent_id: 'agent0', deployment: deployment)
      @instance = Models::Instance.make(vm: vm, deployment: deployment, job: 'job', index: 0)

      @disk = Models::PersistentDisk.make(disk_cid: 'disk0', instance: @instance, active: true)
      Models::Snapshot.make(persistent_disk: @disk, snapshot_cid: 'snap0a', created_at: time, clean: true)
      Models::Snapshot.make(persistent_disk: @disk, snapshot_cid: 'snap0b', created_at: time)

      # instance 2: 1 disk
      vm = Models::Vm.make(cid: 'vm-cid1', agent_id: 'agent1', deployment: deployment)
      instance = Models::Instance.make(vm: vm, deployment: deployment, job: 'job', index: 1)

      disk = Models::PersistentDisk.make(disk_cid: 'disk1', instance: instance, active: true)
      Models::Snapshot.make(persistent_disk: disk, snapshot_cid: 'snap1a', created_at: time)

      # instance 3: no disks
      vm = Models::Vm.make(cid: 'vm-cid2', agent_id: 'agent2', deployment: deployment)
      @instance2 = Models::Instance.make(vm: vm, deployment: deployment, job: 'job2', index: 0)

      # snapshot from another deployment
      Models::Snapshot.make

      Resque.stub(:enqueue)
      JobQueue.any_instance.stub(create_task: task)
    end

    let(:task) { instance_double('Bosh::Director::Models::Task', id: 'task_id') }

    describe 'create_deployment_snapshot_task' do
      it 'should take snapshots of all instances with persistent disks' do
        Resque.should_receive(:enqueue).with(Jobs::SnapshotDeployment, task.id, deployment.name, {})

        expect(subject.create_deployment_snapshot_task(user.username, deployment)).to eq task
      end
    end

    describe 'create_snapshot_task' do
      let(:instance) { instance_double('Bosh::Director::Models::Instance', id: 0) }
      let(:options) { {} }

      it 'should enqueue a CreateSnapshot job' do
        Resque.should_receive(:enqueue).with(Jobs::CreateSnapshot, task.id, instance.id, options)

        expect(subject.create_snapshot_task(user.username, instance, options)).to eq task
      end
    end

    describe 'delete_deployment_snapshots' do
      it 'should enqueue a DeleteDeploymentSnapshots job' do
        Resque.should_receive(:enqueue).with(Jobs::DeleteDeploymentSnapshots, task.id, deployment.name)

        expect(subject.delete_deployment_snapshots_task(user.username, deployment)).to eq task
      end
    end

    describe 'delete_snapshots_task' do
      let(:snapshot_cids) { %w[snap0 snap1] }

      it 'should enqueue a DeleteSnapshot job' do
        Resque.should_receive(:enqueue).with(Jobs::DeleteSnapshots, task.id, snapshot_cids)

        expect(subject.delete_snapshots_task(user.username, snapshot_cids)).to eq task
      end
    end

    describe '#find_by_cid' do
      it 'should return the snapshot with the given id' do
        expect(subject.find_by_cid(deployment, 'snap0a').snapshot_cid).to eq 'snap0a'
      end
    end

    describe '#snapshots' do
      it 'should list all snapshots for a given deployment' do
        response = [
            {'job' => 'job', 'index' => 0, 'snapshot_cid' => 'snap0a', 'created_at' => time, 'clean' => true},
            {'job' => 'job', 'index' => 0, 'snapshot_cid' => 'snap0b', 'created_at' => time, 'clean' => false},
            {'job' => 'job', 'index' => 1, 'snapshot_cid' => 'snap1a', 'created_at' => time, 'clean' => false},
        ]
        expect(subject.snapshots(deployment)).to eq response
      end

      it 'should list all snapshots for a given instance' do
        response = [
            {'job' => 'job', 'index' => 0, 'snapshot_cid' => 'snap0a', 'created_at' => time, 'clean' => true},
            {'job' => 'job', 'index' => 0, 'snapshot_cid' => 'snap0b', 'created_at' => time, 'clean' => false},
        ]
        expect(subject.snapshots(deployment, 'job', 0)).to eq response
      end
    end

    describe 'class methods' do
      let(:config) { Psych.load_file(asset('test-director-config.yml')) }

      before do
        Config.configure(config)
        Config.stub(:enable_snapshots).and_return(true)
      end

      describe '#delete_snapshots' do
        it 'deletes the snapshots' do
          Config.cloud.should_receive(:delete_snapshot).with('snap0a')
          Config.cloud.should_receive(:delete_snapshot).with('snap0b')

          expect {
            described_class.delete_snapshots(@disk.snapshots)
          }.to change { Models::Snapshot.count }.by -2
        end
      end

      describe '#take_snapshot' do
        let(:metadata) {
          {
              agent_id: 'agent0',
              instance_id: 1,
              director_name: 'Test Director',
              director_uuid: Config.uuid,
              deployment: 'deployment',
              job: 'job',
              index: 0
          }
        }

        context 'when there is no persistent disk' do
          it 'does not take a snapshot' do
            Config.cloud.should_not_receive(:snapshot_disk)

            expect {
              described_class.take_snapshot(@instance2, {})
            }.to_not change { Models::Snapshot.count }
          end
        end

        it 'takes the snapshot' do
          Config.cloud.should_receive(:snapshot_disk).with('disk0', metadata).and_return('snap0c')

          expect {
            expect(described_class.take_snapshot(@instance, {})).to eq %w[snap0c]
          }.to change { Models::Snapshot.count }.by 1
        end

        context 'with the clean option' do
          it 'it sets the clean column to true in the db' do
            Config.cloud.should_receive(:snapshot_disk).with('disk0', metadata).and_return('snap0c')
            expect(described_class.take_snapshot(@instance, {:clean => true})).to eq %w[snap0c]

            snapshot = Models::Snapshot.find(snapshot_cid: 'snap0c')
            expect(snapshot.clean).to be(true)
          end
        end

        context 'when snapshotting is disabled' do
          it 'does nothing' do
            Config.stub(:enable_snapshots).and_return(false)

            expect(described_class.take_snapshot(@instance)).to be_empty
          end
        end

        context 'with a CPI that does not support snapshots' do
          it 'does nothing' do
            Config.cloud.stub(:snapshot_disk).and_raise(Bosh::Clouds::NotImplemented)

            expect(described_class.take_snapshot(@instance)).to be_empty
          end
        end
      end
    end
  end
end
