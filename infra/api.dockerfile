FROM rhub/r-minimal:4.4

ENV LIBARROW_BINARY=FALSE
ENV LIBARROW_BUILD=TRUE
ENV LIBARROW_MINIMAL=FALSE
ENV ARROW_S3=ON
ENV ARROW_DATASET=ON
ENV ARROW_WITH_MUSL=ON
ENV ARROW_WITH_RE2=OFF

RUN mkdir -p ~/.R && echo "LDFLAGS+=-fPIC" >> ~/.R/Makevars \
    && installr \
       -c \
       -t "make openssl-dev cmake linux-headers curl-dev" \
       -a "openssl curl" \
       arrow
    
RUN installr \
    -d \
    -t "make openssl-dev cmake linux-headers gfortran proj-dev gdal-dev sqlite-dev geos-dev udunits-dev libsodium-dev curl-dev libpng-dev libxml2-dev" \
    -a "proj gdal geos expat udunits libsodium libpng libxml2" \
    sf plumber logger cachem qs jsonlite rlang "mikejohnson51/zonal" "lynker-spatial/hfsubsetR" \
    && mkdir -p /api

COPY ./api /api
WORKDIR /api
ENV HFSUBSET_API_HOST=0.0.0.0
ENV HFSUBSET_API_PORT=8080

EXPOSE ${HFSUBSET_API_PORT}
CMD ["Rscript", "plumber.R"]
