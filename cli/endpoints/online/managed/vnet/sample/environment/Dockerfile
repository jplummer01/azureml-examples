# Start from a azure ml inference curated base image
FROM mcr.microsoft.com/azureml/minimal-py312-inference:latest

# copy the conda.yaml inside the container
COPY conda.yaml /tmp/conda.yaml

# azure ml curated image has dependencies installed in a conda env called amlenv. Lets add our dependencies to the same env.
RUN conda env update -n amlenv --file /tmp/conda.yaml
