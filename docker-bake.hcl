variable "PLATFORMS" {
  default = ["linux/amd64", "linux/arm64"]
}

variable "TOOLBOX_IMAGE" {
  default = "leavevm0cl6/cross-toolbox"
}

variable "TOOLCHAIN_IMAGE" {
  default = "leavevm0cl6/cross-toolchain"
}

variable "EBPF_IMAGE" {
  default = "leavevm0cl6/ebpf-builder"
}

variable "VERSION" {
  default = "1.0"
}

group "default" {
  targets = ["cross-toolchain"]
}

group "phase-images" {
  targets = ["phase1", "phase2", "phase3", "phase4"]
}

group "all" {
  targets = ["phase1", "phase2", "phase3", "phase4", "cross-toolchain", "ebpf-builder"]
}

target "phase1" {
  context    = "."
  dockerfile = "Dockerfile.phase1"
  platforms  = PLATFORMS
  tags       = ["${TOOLBOX_IMAGE}:phase1"]
}

target "phase2" {
  context    = "."
  dockerfile = "Dockerfile.phase2"
  platforms  = PLATFORMS
  tags       = ["${TOOLBOX_IMAGE}:phase2"]
}

target "phase3" {
  context    = "."
  dockerfile = "Dockerfile.phase3"
  platforms  = PLATFORMS
  tags       = ["${TOOLBOX_IMAGE}:phase3"]
}

target "phase4" {
  context    = "."
  dockerfile = "Dockerfile.phase4"
  platforms  = PLATFORMS
  tags       = ["${TOOLBOX_IMAGE}:phase4"]
}

target "cross-toolchain" {
  context    = "."
  dockerfile = "Dockerfile.all"
  platforms  = PLATFORMS
  tags = [
    "${TOOLCHAIN_IMAGE}:${VERSION}",
    "${TOOLCHAIN_IMAGE}:latest",
  ]
}

target "ebpf-builder" {
  context    = "."
  dockerfile = "Dockerfile.ebpf-builder"
  platforms  = PLATFORMS
  tags = [
    "${EBPF_IMAGE}:${VERSION}",
    "${EBPF_IMAGE}:latest",
  ]
}
