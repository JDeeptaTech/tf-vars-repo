include .env
export $(shell sed 's/=.*//' .env)

.PHONY: run
run:
	@echo "Running the script"
	@ansible-playbook -i localhost main.yaml -vvv --extra-vars @test01-vars.yaml
