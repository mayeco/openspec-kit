# Jev calibration fixtures

Synthetic states for `bin/jev_contract.sh --live`: one clearly good and one clearly bad state per gate, plus a failing gate log for the canary. They describe no real change of this workspace, so never queue work from them.

Run `bash bin/jev_contract.sh --live` after changing `config/jev_policy.yaml`, the pinned Jev model or a question file under `templates/jev/`, and before switching any gate to `enforce`. Every check must pass; a right answer below a routing threshold is reported as a warning to tune.
