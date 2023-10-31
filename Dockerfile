FROM rocker/geospatial:4.3.0

COPY --from=public.ecr.aws/lambda/provided:al2.2023.05.13.00 /lambda-entrypoint.sh /lambda-entrypoint.sh
COPY --from=public.ecr.aws/lambda/provided:al2.2023.05.13.00 /usr/local/bin/aws-lambda-rie /usr/local/bin/aws-lambda-rie
ENV LAMBDA_TASK_ROOT=/var/task
ENV LAMBDA_RUNTIME_DIR=/var/runtime

RUN mkdir ${LAMBDA_RUNTIME_DIR}
RUN mkdir ${LAMBDA_TASK_ROOT}
WORKDIR ${LAMBDA_TASK_ROOT}
ENTRYPOINT ["/lambda-entrypoint.sh"]

# Tnstall Apache Arrow/build tools
ENV HF_BUILD_PKGS="build-essential git"
ENV HF_ARROW_PKGS="libarrow-dev libarrow-glib-dev libarrow-dataset-dev libarrow-dataset-glib-dev libarrow-flight-dev libarrow-flight-glib-dev libparquet-dev libparquet-glib-dev"
RUN apt update \
    && apt install -y -V ca-certificates lsb-release wget \
    && wget https://apache.jfrog.io/artifactory/arrow/$(lsb_release --id --short | tr 'A-Z' 'a-z')/apache-arrow-apt-source-latest-$(lsb_release --codename --short).deb \
    && apt install -y -V ./apache-arrow-apt-source-latest-$(lsb_release --codename --short).deb \
    && apt update \
    && apt install -y -V ${HF_BUILD_PKGS} ${HF_ARROW_PKGS}

# Setup hydrofabric location
# RUN git clone https://github.com/NOAA-OWP/hydrofabric.git /hydrofabric \
RUN mkdir -p /hydrofabric/subset

# Install CRAN Packages
ENV HF_CRAN_R_PKGS="arrow aws.s3 base64enc box DBI dplyr glue lambdr logger nhdplusTools pak readr RSQLite sf"
RUN cd /hydrofabric \
    && . /etc/lsb-release \
    && echo "options(ncpus = $(nproc --all))" >> .Rprofile \
    && install2.r -r https://cloud.r-project.org/ \
                  -e \
                  -n 6 \
                  -s \
                  ${HF_CRAN_R_PKGS}

COPY . /hydrofabric/subset

RUN cd /hydrofabric \
    && chmod 755 subset/runtime.R \
    && printf "#!/bin/sh\ncd /hydrofabric/subset\nRscript runtime.R" > /var/runtime/bootstrap \
    && chmod +x /var/runtime/bootstrap

CMD ["subset"]
