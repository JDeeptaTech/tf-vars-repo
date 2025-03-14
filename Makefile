include .env
export $(shell sed 's/=.*//' .env)

.PHONY: create-vm1
create-vm1:
	@echo "Running the script"
	@ansible-playbook -i localhost main.yaml -vvv --extra-vars @vm01-vars.yaml

.PHONY: create-vm2
create-vm2:
	@echo "Running the script"
	@ansible-playbook -i localhost main.yaml -vvv --extra-vars @vm02-vars.yaml

.PHONY: show-yaml
show-yaml:
	@python3 -c "import yaml, pprint; pprint.pprint(yaml.safe_load(open('main.yaml')))"
