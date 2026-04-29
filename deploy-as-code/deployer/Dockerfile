FROM golang:1.24-alpine AS build

ENV GO111MODULE=on
ENV GOCACHE=/tmp

ARG WORK_DIR
WORKDIR /app

COPY ${WORK_DIR}/go.mod .
COPY ${WORK_DIR}/go.sum .

RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o egov-deployer


# Create runtime image
FROM alpine:3

ARG KUBECTL_VERSION=v1.26.2
ARG AWS_IAM_AUTH_VERSION=v0.7.8
ARG SOPS_VERSION=v3.7.3
ARG HELM_VERSION=v3.19.0

ENV CLOUDSDK_VERSION=472.0.0
ENV CLOUDSDK_CORE_DISABLE_PROMPTS=1
ENV USE_GKE_GCLOUD_AUTH_PLUGIN=True
ENV HELMFILE_VERSION=0.163.1
ENV HELM_DATA_HOME=/usr/local/share/helm
ENV PATH="/usr/local/gcloud/bin:$PATH"

WORKDIR /opt/egov

RUN addgroup -S egov && adduser -S -G egov egov

COPY --chown=egov:egov --from=build /app/egov-deployer /opt/egov/
RUN chmod +x /opt/egov/egov-deployer

# Install base tools and kubectl/sops/helm
RUN apk update && apk upgrade && apk add --no-cache \
      curl git bash gnupg unzip bind-tools python3 py3-crcmod libc6-compat wget \
    && wget https://storage.googleapis.com/kubernetes-release/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl \
    && wget https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/download/$AWS_IAM_AUTH_VERSION/aws-iam-authenticator_${AWS_IAM_AUTH_VERSION#v}_linux_amd64 -O aws-iam-authenticator \
    && wget -O sops https://github.com/mozilla/sops/releases/download/$SOPS_VERSION/sops-$SOPS_VERSION.linux \
    && wget -qO- https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz | tar xvz \
    && chmod +x ./kubectl ./aws-iam-authenticator ./sops ./linux-amd64/helm \
    && mv ./kubectl ./aws-iam-authenticator ./sops ./linux-amd64/helm /usr/local/bin \
    && rm -rf ./linux-amd64 && rm -f /var/cache/apk/*

# Install Google Cloud SDK with GKE auth plugin
RUN curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-${CLOUDSDK_VERSION}-linux-x86_64.tar.gz \
    && tar -xzf google-cloud-sdk-${CLOUDSDK_VERSION}-linux-x86_64.tar.gz \
    && mv google-cloud-sdk /usr/local/gcloud \
    && rm google-cloud-sdk-${CLOUDSDK_VERSION}-linux-x86_64.tar.gz \
    && /usr/local/gcloud/install.sh --quiet \
    && ln -s /usr/local/gcloud/bin/gcloud /usr/local/bin/gcloud \
    && ln -s /usr/local/gcloud/bin/gsutil /usr/local/bin/gsutil \
    && gcloud components install gke-gcloud-auth-plugin --quiet

# Install helmfile
RUN curl -L -o helmfile.tar.gz https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz \
    && tar -xzf helmfile.tar.gz \
    && mv helmfile /usr/local/bin/helmfile \
    && chmod +x /usr/local/bin/helmfile \
    && rm helmfile.tar.gz

# Install helm plugins to a shared location accessible by the egov user
RUN mkdir -p ${HELM_DATA_HOME}/plugins \
    && helm plugin install https://github.com/databus23/helm-diff \
    && helm plugin install https://github.com/jkroepke/helm-secrets --version v4.4.2 \
    && helm plugin install https://github.com/aslafy-z/helm-git --version 0.14.3 \
    && helm plugin install https://github.com/hypnoglow/helm-s3.git --version 0.14.0 \
    && chmod -R 755 ${HELM_DATA_HOME}

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD test -x /opt/egov/egov-deployer \
    && test -x /usr/local/bin/kubectl \
    && test -x /usr/local/bin/aws-iam-authenticator \
    && test -x /usr/local/bin/sops \
    && test -x /usr/local/bin/helm \
    || exit 1

USER egov
