package action

import (
	boshtask "bosh/agent/task"
	boshblobstore "bosh/blobstore"
	boshplatform "bosh/platform"
	boshsettings "bosh/settings"
)

type concreteFactory struct {
	availableActions map[string]Action
}

func NewFactory(settings boshsettings.Settings, platform boshplatform.Platform, blobstore boshblobstore.Blobstore, taskService boshtask.Service) (factory Factory) {
	fs := platform.GetFs()

	factory = concreteFactory{
		availableActions: map[string]Action{
			"apply":      newApply(fs),
			"ping":       newPing(),
			"get_task":   newGetTask(taskService),
			"get_state":  newGetState(settings, fs),
			"ssh":        newSsh(settings, platform),
			"fetch_logs": newLogs(platform, blobstore),
		},
	}
	return
}

func (f concreteFactory) Create(method string) (action Action) {
	return f.availableActions[method]
}
