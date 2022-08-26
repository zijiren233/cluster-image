#!/bin/bash

set -eu

readonly ARCH=${arch?}
readonly CRI_TYPE=${criType?}
readonly KUBE=${kubeVersion?}
readonly SEALOS=${sealos?}

readonly ipvsImage="ghcr.io/labring/lvscare:v$SEALOS"

readonly IMAGE_HUB_REGISTRY=${registry?}
readonly IMAGE_HUB_REPO=${repo?}
readonly IMAGE_HUB_USERNAME=${username?}
readonly IMAGE_HUB_PASSWORD=${password?}

readonly ROOT="/tmp/$(whoami)/build"
mkdir -p "$ROOT"
readonly downloadDIR="/tmp/$(whoami)/download"
readonly binDIR="/tmp/$(whoami)/bin"

{
  wget -qP "$binDIR" "https://storage.googleapis.com/kubernetes-release/release/v$KUBE/bin/linux/amd64/kubeadm"
  chmod a+x "$binDIR"/*
  sudo cp -auv "$binDIR"/* /usr/bin
}

cp -a rootfs/* "$ROOT"
cp -a "$CRI_TYPE"/* "$ROOT"

tree "/tmp/$(whoami)"
cd "$ROOT" && {
  mkdir -p bin
  mkdir -p opt
  mkdir -p registry
  mkdir -p images/shim
  mkdir -p cri/lib64

  # ImageList
  echo "$ipvsImage" >images/shim/LvscareImageList
  kubeadm config images list --kubernetes-version "$KUBE" 2>/dev/null >images/shim/DefaultImageList

  # library
  TARGZ="${downloadDIR}/$ARCH/library.tar.gz"
  {
    cd bin && {
      tar -zxf "$TARGZ" library/bin --strip-components=2
      cd -
    }
    case $CRI_TYPE in
    containerd)
      cd cri/lib64 && {
        tar -zxf "$TARGZ" library/lib64 --strip-components=2
        mkdir -p lib
        mv libseccomp.* lib
        tar -czf containerd-lib.tar.gz lib
        rm -rf lib
        cd -
      }
      ;;
    esac
  }

  # cri
  case $CRI_TYPE in
  containerd)
    cp -a "${downloadDIR}/$ARCH/cri-containerd.tar.gz" cri/
    cp -a "${downloadDIR}/$ARCH/nerdctl" cri/
    ;;
  docker)
    case $KUBE in
    1.[2-9][4-9].*)
      cp -a "${downloadDIR}/$ARCH/cri-dockerd.tgz" cri/
      ;;
    *)
      cp -a "${downloadDIR}/$ARCH/docker.tgz" cri/
      ;;
    esac
    ;;
  esac

  cp -a "${downloadDIR}/$ARCH"/kube* bin/
  cp -a "${downloadDIR}/$ARCH"/registry.tar images/
  cp -a "${downloadDIR}/$ARCH"/image-cri-shim cri/
  cp -a "${downloadDIR}/$ARCH"/sealctl opt/
  cp -a "${downloadDIR}/$ARCH"/lsof opt/

  # replace
  sed -i "s#__lvscare__#$ipvsImage#g;s/v0.0.0/v$KUBE/g" "Kubefile"
  pauseImage=$(grep /pause: images/shim/DefaultImageList)
  sed -i "s#__pause__#${pauseImage}#g" etc/kubelet-flags.env
  case $CRI_TYPE in
  containerd)
    sed -i "s#__pause__#sealos.hub:5000/${pauseImage#*/}#g" etc/config.toml
    ;;
  docker)
    sed -i "s#__pause__#{{ .registryDomain }}:{{ .registryPort }}/${pauseImage#*/}#g" etc/cri-docker.service.tmpl
    ;;
  esac

  # build
  case $CRI_TYPE in
  containerd)
    IMAGE_KUBE=kubernetes
    ;;
  docker)
    IMAGE_KUBE=kubernetes-docker
    ;;
  esac
  tree
  chmod a+x bin/* opt/*
  sudo sealos build -t "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v${KUBE}-$ARCH" --platform "linux/$ARCH" -f Kubefile .
  sudo sealos login "$IMAGE_HUB_REGISTRY" -u "$IMAGE_HUB_USERNAME" -p "$IMAGE_HUB_PASSWORD"
  sudo sealos push "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v${KUBE}-$ARCH"
}