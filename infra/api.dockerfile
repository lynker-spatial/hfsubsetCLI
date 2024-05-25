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
    sf plumber logger "lynker-spatial/hfsubsetR" \
    && mkdir -p /api

# RUN apk add --no-cache fuse \
#     && wget https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.tar.gz \
#     && mkdir -p /opt/aws/mountpoint-s3 \
#     && tar -C /opt/aws/mountpoint-s3 -xzf ./mount-s3.tar.gz \
#     && mkdir -p /api/mnt \
#     && mkdir -p /api/cache

COPY ./api /api
WORKDIR /api
ENV HFSUBSET_API_HOST=0.0.0.0
ENV HFSUBSET_API_PORT=8080

# ENV HFSUBSET_API_MOUNT=/api/mnt
# RUN /opt/aws/mountpoint-s3/bin/mount-s3 \
#     # --prefix "hydrofabric/" \
#     # --region "us-west-2" \
#     # --cache "/api/cache" \
#     --read-only \
#     --no-log \
#     lynker-spatial /api/mnt

EXPOSE ${HFSUBSET_API_PORT}
CMD ["Rscript", "plumber.R"]
