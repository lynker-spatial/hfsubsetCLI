
GIT_COMMIT=$(shell git rev-parse --short HEAD)
AWS_REGION=us-west-2
AWS_ACCOUNT_ID=$(shell aws sts get-caller-identity --query Account --output text)
AWS_ECR_ENDPOINT=$(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com

docker:
	docker build -f infra/api.dockerfile -t hfsubset:latest .

ecr: docker
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(AWS_ECR_ENDPOINT)
	docker tag hfsubset:latest $(AWS_ECR_ENDPOINT)/hfsubset:latest
	docker tag hfsubset:latest $(AWS_ECR_ENDPOINT)/hfsubset:$(GIT_COMMIT)
	docker push $(AWS_ECR_ENDPOINT)/hfsubset:latest
	docker push $(AWS_ECR_ENDPOINT)/hfsubset:$(GIT_COMMIT)

