#!/bin/bash

# VM 설정 파일 경로
CONFIG_FILE="vm-config.ini"

# 사용법 출력 함수
usage() {
    echo "사용법:"
    echo "  단일 VM 생성: $0 <vm-name>"
    echo "  설정 파일의 모든 VM 생성: $0 --all"
    echo "  설정 파일 생성: $0 --create-config"
    echo "예시:"
    echo "  $0 vm01     # vm01 생성"
    echo "  $0 --all    # 설정 파일의 모든 VM 생성"
    exit 1
}

# 설정 파일 생성 함수
create_config() {
    if [ -f "${CONFIG_FILE}" ]; then
        echo "설정 파일이 이미 존재합니다: ${CONFIG_FILE}"
        read -p "덮어쓰시겠습니까? (y/n): " confirm
        if [ "$confirm" != "y" ]; then
            echo "설정 파일 생성을 취소합니다."
            exit 0
        fi
    fi
    
    cat > "${CONFIG_FILE}" << 'EOF'
# VM 설정 파일
# 형식: [VM이름]
#       ram=메모리크기(MB)
#       vcpus=CPU코어수
#       disk_size=디스크크기(예: 10G)
#       ip_address=IP주소(예: 192.168.219.140/24)
#       gateway=게이트웨이(예: 192.168.219.1)
#       dns=DNS서버(예: 8.8.8.8)

[vm01]
ram=4092
vcpus=2
disk_size=10G
ip_address=192.168.219.140/24
gateway=192.168.219.1
dns=8.8.8.8

[vm02]
ram=8192
vcpus=8
disk_size=10G
ip_address=192.168.219.141/24
gateway=192.168.219.1
dns=8.8.8.8

[vm03]
ram=4092
vcpus=2
disk_size=10G
ip_address=192.168.219.142/24
gateway=192.168.219.1
dns=8.8.8.8
EOF
    
    echo "설정 파일이 생성되었습니다: ${CONFIG_FILE}"
    echo "이 파일을 편집하여 VM 설정을 변경할 수 있습니다."
    exit 0
}

# VM 생성 함수
create_vm() {
    local VM_NAME=$1
    local VM_RAM=$2
    local VM_VCPUS=$3
    local VM_DISK_SIZE=$4
    local VM_IP_ADDRESS=$5
    local VM_GATEWAY=$6
    local VM_DNS=$7
    local VM_OS_VARIANT="ubuntu20.04"
    local BASE_IMAGE_DIR="img"
    local BASE_IMAGE="$(pwd)/${BASE_IMAGE_DIR}/focal-server-cloudimg-amd64.img"
    local NETWORK="br0-net"

    # 루트 디렉토리 (스크립트가 실행되는 디렉토리)
    local ROOT_DIR=$(pwd)

    # VM 디렉토리 확인 및 생성
    local VM_DIR="${ROOT_DIR}/${VM_NAME}"
    if [ ! -d "${VM_DIR}" ]; then
        echo "VM 디렉토리를 생성합니다: ${VM_DIR}"
        mkdir -p "${VM_DIR}"
    fi

    # VM 이미지 파일 경로
    local VM_DISK="${VM_DIR}/vm-disk.qcow2"
    local VM_BASE="${VM_DIR}/${VM_NAME}-base.qcow2"

    # 실행 중인 VM 확인 및 삭제
    if virsh domstate ${VM_NAME} >/dev/null 2>&1; then
        echo "기존 VM을 중지하고 삭제합니다: ${VM_NAME}"
        virsh destroy ${VM_NAME} >/dev/null 2>&1
        virsh undefine ${VM_NAME} >/dev/null 2>&1
    fi

    # 베이스 이미지 확인
    if [ ! -f "${BASE_IMAGE}" ]; then
        echo "베이스 이미지가 존재하지 않습니다: ${BASE_IMAGE}"
        echo "ubuntu cloud 이미지를 다운로드하세요:"
        echo "wget https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img -O ${BASE_IMAGE}"
        return 1
    fi

    # VM 설정 파일 확인 및 생성
    if [ ! -f "${VM_DIR}/user-data" ]; then
        echo "user-data 파일이 없습니다. 기본 user-data 파일을 생성합니다."
        cat > "${VM_DIR}/user-data" << 'EOF'
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin
    home: /home/ubuntu
    shell: /bin/bash
    lock_passwd: false
ssh_pwauth: true
disable_root: false
chpasswd:
  list: |
    ubuntu:ubuntu
  expire: false

# 시간 관련 설정 추가
timezone: Asia/Seoul

# 패키지 업데이트 및 설치
package_update: true
package_upgrade: true

# 설치할 패키지
packages:
  - chrony
  - apt-transport-https

# 사용자 지정 스크립트
write_files:
  # APT 설정 최적화
  - path: /etc/apt/apt.conf.d/99custom
    content: |
      Acquire::http::Pipeline-Depth "0";
      Acquire::https::Pipeline-Depth "0";
      Acquire::http::Timeout "60";
      Acquire::Retries "3";
    permissions: '0644'
    owner: root:root

  # IPv4 강제 사용
  - path: /etc/apt/apt.conf.d/99force-ipv4
    content: |
      Acquire::ForceIPv4 "true";
    permissions: '0644'
    owner: root:root
EOF

        # user-data 파일에서 ${VM_NAME}을 실제 VM 이름으로 치환
        sed -i "s/\${VM_NAME}/${VM_NAME}/g" "${VM_DIR}/user-data"
    fi

    if [ ! -f "${VM_DIR}/meta-data" ]; then
        echo "meta-data 파일이 없습니다. 기본 meta-data 파일을 생성합니다."
        cat > "${VM_DIR}/meta-data" << EOF
local-hostname: ${VM_NAME}
EOF
    fi

    # 네트워크 설정 파일 생성
    echo "network-config 파일을 생성합니다."
    if [ -n "${VM_IP_ADDRESS}" ] && [ -n "${VM_GATEWAY}" ] && [ -n "${VM_DNS}" ]; then
        # 고정 IP 설정
        cat > "${VM_DIR}/network-config" << EOF
version: 2
ethernets:
  enp1s0:
    dhcp4: false
    dhcp6: false
bridges:
  br0:
    interfaces: 
      - enp1s0
    addresses:
      - ${VM_IP_ADDRESS}
    gateway4: ${VM_GATEWAY}
    nameservers:
      addresses: 
        - ${VM_DNS}
    parameters:
      stp: false
      forward-delay: 0
EOF
    else
        # DHCP 설정
        cat > "${VM_DIR}/network-config" << 'EOF'
version: 2
ethernets:
  enp1s0:
    dhcp4: true
    dhcp6: false
EOF
    fi

    # 기존 이미지 삭제
    if [ -f "${VM_DISK}" ]; then
        echo "기존 디스크 이미지를 삭제합니다: ${VM_DISK}"
        rm -f "${VM_DISK}"
    fi

    if [ -f "${VM_BASE}" ]; then
        echo "기존 베이스 이미지를 삭제합니다: ${VM_BASE}"
        rm -f "${VM_BASE}"
    fi

    # cloud-init 이미지 생성
    echo "cloud-init 이미지를 생성합니다: ${VM_BASE}"
    cd "${VM_DIR}"
    cloud-localds -v --network-config=network-config "${VM_NAME}-base.qcow2" user-data meta-data
    cd "${ROOT_DIR}"

    if [ $? -ne 0 ]; then
        echo "cloud-init 이미지 생성에 실패했습니다."
        return 1
    fi

    # 디스크 이미지 생성
    echo "디스크 이미지를 생성합니다: ${VM_DISK}"
    qemu-img create -F qcow2 -b "${BASE_IMAGE}" -f qcow2 "${VM_DISK}" "${VM_DISK_SIZE}"

    if [ $? -ne 0 ]; then
        echo "디스크 이미지 생성에 실패했습니다."
        return 1
    fi

    # VM 생성 실행
    echo "VM을 생성합니다: ${VM_NAME} (RAM: ${VM_RAM}MB, vCPUs: ${VM_VCPUS}, Disk: ${VM_DISK_SIZE}, IP: ${VM_IP_ADDRESS})"
    virt-install \
      --virt-type kvm \
      --name ${VM_NAME} \
      --ram ${VM_RAM} \
      --vcpus ${VM_VCPUS} \
      --os-variant ${VM_OS_VARIANT} \
      --disk path=${VM_DISK},device=disk \
      --disk path=${VM_BASE},device=disk \
      --import \
      --network network:${NETWORK} \
      --noautoconsole

    # 결과 확인
    if virsh list --all | grep -q "${VM_NAME}"; then
        echo "VM이 성공적으로 생성되었습니다: ${VM_NAME}"
        echo "VM 디렉토리: ${VM_DIR}"
        echo "VM 콘솔에 접속하려면: virsh console ${VM_NAME}"
        echo "VM IP 확인하려면: virsh domifaddr ${VM_NAME}"
        return 0
    else
        echo "VM 생성에 실패했습니다: ${VM_NAME}"
        return 1
    fi
}

# 설정 파일에서 VM 설정 읽기
read_vm_config() {
    local VM_NAME=$1
    
    # 설정 파일에서 VM 섹션 찾기
    if ! grep -q "^\[${VM_NAME}\]$" "$CONFIG_FILE"; then
        echo "설정 파일에서 VM '${VM_NAME}'을 찾을 수 없습니다."
        return 1
    fi
    
    # 설정 값 읽기 (더 간단한 방법으로 수정)
    local RAM=$(grep -A 20 "^\[${VM_NAME}\]$" "$CONFIG_FILE" | grep "^ram=" | head -1 | cut -d= -f2)
    local VCPUS=$(grep -A 20 "^\[${VM_NAME}\]$" "$CONFIG_FILE" | grep "^vcpus=" | head -1 | cut -d= -f2)
    local DISK_SIZE=$(grep -A 20 "^\[${VM_NAME}\]$" "$CONFIG_FILE" | grep "^disk_size=" | head -1 | cut -d= -f2)
    local IP_ADDRESS=$(grep -A 20 "^\[${VM_NAME}\]$" "$CONFIG_FILE" | grep "^ip_address=" | head -1 | cut -d= -f2)
    local GATEWAY=$(grep -A 20 "^\[${VM_NAME}\]$" "$CONFIG_FILE" | grep "^gateway=" | head -1 | cut -d= -f2)
    local DNS=$(grep -A 20 "^\[${VM_NAME}\]$" "$CONFIG_FILE" | grep "^dns=" | head -1 | cut -d= -f2)
    
    # 기본값 설정
    RAM=${RAM:-4092}
    VCPUS=${VCPUS:-2}
    DISK_SIZE=${DISK_SIZE:-10G}
    
    echo "VM '${VM_NAME}' 설정: RAM=${RAM}MB, vCPUs=${VCPUS}, Disk=${DISK_SIZE}, IP=${IP_ADDRESS}, Gateway=${GATEWAY}, DNS=${DNS}"
    
    # VM 생성
    create_vm "$VM_NAME" "$RAM" "$VCPUS" "$DISK_SIZE" "$IP_ADDRESS" "$GATEWAY" "$DNS"
    return $?
}

# 설정 파일의 모든 VM 생성
create_all_vms() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "설정 파일이 존재하지 않습니다: $CONFIG_FILE"
        create_config
        return 1
    fi
    
    echo "설정 파일에서 모든 VM을 생성합니다: $CONFIG_FILE"
    
    # 설정 파일에서 모든 VM 섹션 찾기 (수정된 방법)
    local VM_NAMES=$(grep -o '^\[[^]]*\]$' "$CONFIG_FILE" | tr -d '[]')
    
    if [ -z "$VM_NAMES" ]; then
        echo "설정 파일에 VM이 정의되어 있지 않습니다."
        return 1
    fi
    
    # 각 VM 생성
    local TOTAL_VMS=$(echo "$VM_NAMES" | wc -l)
    local SUCCESS_COUNT=0
    
    for VM_NAME in $VM_NAMES; do
        echo "======================================================"
        echo "VM 생성 ($((SUCCESS_COUNT+1))/$TOTAL_VMS): $VM_NAME"
        echo "======================================================"
        
        read_vm_config "$VM_NAME"
        if [ $? -eq 0 ]; then
            ((SUCCESS_COUNT++))
        fi
    done
    
    echo "======================================================"
    echo "VM 생성 완료: 총 $TOTAL_VMS 중 $SUCCESS_COUNT 개 성공"
    echo "======================================================"
    
    return 0
}

# 메인 스크립트
main() {
    # 설정 파일 존재 확인
    if [ ! -f "$CONFIG_FILE" ] && [ "$1" != "--create-config" ]; then
        echo "설정 파일이 존재하지 않습니다: $CONFIG_FILE"
        echo "설정 파일을 생성하려면: $0 --create-config"
        exit 1
    fi
    
    # 인자 처리
    if [ $# -lt 1 ]; then
        usage
    fi
    
    case "$1" in
        --all)
            create_all_vms
            ;;
        --create-config)
            create_config
            ;;
        *)
            read_vm_config "$1"
            ;;
    esac
    
    exit $?
}

# 스크립트 실행
main "$@"
