#!/usr/bin/env bash
# Build the image
docker build -t extended-devops-env -f Dockerfile .

# Run with volumes mounted
docker run -it --rm \
  -v $(pwd):/home/devuser/workspace \
  -v ~/.config/openstack/clouds.yaml:/home/devuser/.config/openstack/clouds.yaml:ro \
  -v /var/run/docker.sock:/var/run/docker.sock \
  extended-devops-env
