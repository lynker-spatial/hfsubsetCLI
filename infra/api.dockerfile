FROM debian:12.8-slim

ENV LIBARROW_BUILD=false
ENV LIBARROW_MINIMAL=false
ENV NOT_CRAN=true

RUN apt-get update -y \
    && apt-get install -y \
      libssl-dev \
      libcurl4-openssl-dev \
      r-cran-sf \
      r-cran-terra \
      r-cran-collapse \
      r-cran-data.table \
      r-cran-dbi \
      r-cran-dplyr \
      r-cran-dbplyr \
      r-cran-tidyr \
      r-cran-plumber \
      r-cran-logger \
      r-cran-cachem \
      r-cran-jsonlite \
      r-cran-rlang \
      r-cran-remotes \
      r-cran-rcpp \
      r-cran-bh

RUN echo 'options(repos = c(CRAN = "https://packagemanager.posit.co/cran/__linux__/bookworm/latest"))' > .Rprofile \
    && Rscript -e 'install.packages(c("arrow", "qs"))' \
    && Rscript -e 'remotes::install_github(c("mikejohnson51/zonal", "lynker-spatial/hfsubsetR"))'

RUN Rscript -e 'install.packages("logger")'

RUN mkdir -p /api

COPY ./api /api
WORKDIR /api
ENV HFSUBSET_API_HOST=0.0.0.0
ENV HFSUBSET_API_PORT=8080

EXPOSE ${HFSUBSET_API_PORT}
CMD ["Rscript", "plumber.R"]


