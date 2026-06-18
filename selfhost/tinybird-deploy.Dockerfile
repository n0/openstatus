# Bakes the OpenStatus Tinybird data project and the provisioning script into the
# Classic Tinybird CLI image, so a one-shot container can `tb push` the datasources,
# materialized views, and endpoint pipes into the local Tinybird container.
FROM tinybirdco/tinybird-cli-docker:latest

COPY packages/tinybird/datasources /project/datasources
COPY packages/tinybird/pipes /project/pipes
COPY packages/tinybird/endpoints /project/endpoints
COPY selfhost/tinybird-deploy.sh /deploy.sh

WORKDIR /project
ENTRYPOINT ["sh", "/deploy.sh"]
