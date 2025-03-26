#!/bin/bash

# 定义颜色变量
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 是否输出JSON格式
JSON_OUTPUT=false

# 获取当前日期和时间
current_date=$(date "+%Y年%m月%d日 %A %H:%M:%S")
# 获取主机名
get_hostname() {
    if command -v hostname &> /dev/null; then
        hostname
    elif [ -f "/etc/hostname" ]; then
        cat /etc/hostname
    else
        uname -n
    fi
}
hostname=$(get_hostname)

# JSON数据临时存储
declare -A json_data

# 获取主板信息
get_pm_info() {
    echo -e "${YELLOW}主板信息:${NC}"
    
    # 检测虚拟化环境
    local virt_type=""
    if command -v systemd-detect-virt &> /dev/null; then
        virt_type=$(systemd-detect-virt)
    elif command -v virt-what &> /dev/null; then
        virt_type=$(virt-what)
    elif grep -q "^flags.*hypervisor" /proc/cpuinfo; then
        virt_type="Virtual Machine"
    elif [ -f "/sys/devices/virtual/dmi/id/product_name" ]; then
        virt_type=$(cat /sys/devices/virtual/dmi/id/product_name)
    elif dmesg 2>/dev/null | grep -qi "kvm"; then
        virt_type="KVM"
    elif dmesg 2>/dev/null | grep -qi "xen"; then
        virt_type="Xen"
    elif dmesg 2>/dev/null | grep -qi "vmware"; then
        virt_type="VMware"
    fi
    
    if [ ! -z "$virt_type" ]; then
        echo -e "${GREEN}虚拟化类型: $virt_type${NC}"
    fi

    # 尝试从多个来源获取主板/系统信息
    local info_found=false

    # 1. 尝试/sys/devices/virtual/dmi/id/
    if [ -d "/sys/devices/virtual/dmi/id/" ]; then
        local product_name=""
        local sys_vendor=""
        local product_version=""
        
        [ -f "/sys/devices/virtual/dmi/id/product_name" ] && product_name=$(cat /sys/devices/virtual/dmi/id/product_name)
        [ -f "/sys/devices/virtual/dmi/id/sys_vendor" ] && sys_vendor=$(cat /sys/devices/virtual/dmi/id/sys_vendor)
        [ -f "/sys/devices/virtual/dmi/id/product_version" ] && product_version=$(cat /sys/devices/virtual/dmi/id/product_version)
        
        if [ ! -z "$product_name" ] || [ ! -z "$sys_vendor" ] || [ ! -z "$product_version" ]; then
            [ ! -z "$sys_vendor" ] && echo -e "${GREEN}系统供应商: $sys_vendor${NC}"
            [ ! -z "$product_name" ] && echo -e "${GREEN}产品名称: $product_name${NC}"
            [ ! -z "$product_version" ] && echo -e "${GREEN}产品版本: $product_version${NC}"
            info_found=true
        fi
    fi

    # 2. 尝试dmidecode
    if [ "$info_found" = false ] && command -v dmidecode &> /dev/null; then
        if dmidecode -t 1 2>/dev/null | grep -q -E "Manufacturer|Product"; then
            dmidecode -t 1 2>/dev/null | grep -E "Manufacturer|Product Name|Serial Number" | while read line; do
                echo -e "${GREEN}$line${NC}"
            done
            info_found=true
        fi
    fi

    # 3. 尝试/proc/cpuinfo
    if [ "$info_found" = false ]; then
        if grep -q "^Hardware\|^Platform\|^Machine\|^System" /proc/cpuinfo; then
            grep "^Hardware\|^Platform\|^Machine\|^System" /proc/cpuinfo | while read line; do
                echo -e "${GREEN}$line${NC}"
            done
            info_found=true
        fi
    fi

    # 如果所有方法都失败
    if [ "$info_found" = false ]; then
        if [ ! -z "$virt_type" ]; then
            echo -e "${GREEN}这是一个虚拟化环境，无法获取更多硬件信息${NC}"
        else
            echo -e "${RED}无法获取系统硬件信息${NC}"
        fi
    fi
}

# 获取CPU信息
get_cpu() {
    echo -e "${YELLOW}CPU信息:${NC}"
    if command -v lscpu &> /dev/null; then
        echo "CPU型号：$(lscpu | grep "型号名称" || lscpu | grep "Model name")" 
        echo "CPU核心数：$(lscpu | grep "CPU(s)" | head -n1)"
        echo "每个核心的线程数：$(lscpu | grep "每个核心的线程数" || lscpu | grep "Thread(s) per core")"
        local cpu_mhz=$(lscpu | grep "CPU MHz" || lscpu | grep "CPU max MHz")
        if [ -z "$cpu_mhz" ]; then
            cpu_mhz=$(grep "cpu MHz" /proc/cpuinfo | head -n1 | cut -d: -f2)
            [ ! -z "$cpu_mhz" ] && echo "CPU当前主频：$cpu_mhz MHz"
        else
            echo "CPU最大主频：$cpu_mhz"
        fi
    else
        echo -e "${RED}lscpu命令不可用，尝试从/proc/cpuinfo获取信息${NC}"
        echo "CPU型号：$(grep "model name" /proc/cpuinfo | head -n1 | cut -d: -f2)"
        echo "CPU核心数：$(grep -c processor /proc/cpuinfo)"
        local cpu_mhz=$(grep "cpu MHz" /proc/cpuinfo | head -n1 | cut -d: -f2)
        [ ! -z "$cpu_mhz" ] && echo "CPU当前主频：$cpu_mhz MHz"
    fi
}

# 获取内存信息
get_mem() {
    echo -e "${YELLOW}内存信息:${NC}"
    
    # 使用free命令获取内存使用情况
    if command -v free &> /dev/null; then
        echo -e "${GREEN}内存使用情况：${NC}"
        free -h | grep -v total | awk '{
            printf "%-8s %10s %10s %10s %10s %10s %10s\n", 
                   $1":", $2, "已用:", $3, "可用:", $7, 
                   ($2 == "0B" ? "" : sprintf("(使用率: %.1f%%)", $3/$2*100))
        }'
    fi

    # 从/proc/meminfo获取详细信息
    if [ -f "/proc/meminfo" ]; then
        total_mem=$(grep MemTotal /proc/meminfo | awk '{printf "%.2f GiB", $2/1024/1024}')
        echo -e "\n${GREEN}内存硬件信息:${NC}"
        echo "----------------------------------------"
        echo "总容量: $total_mem"
        
        # 尝试从/proc/cpuinfo获取内存通道信息
        local channels=0
        if grep -q "physical id" /proc/cpuinfo; then
            channels=$(grep "physical id" /proc/cpuinfo | sort -u | wc -l)
            echo "内存通道数: ${channels}通道"
        fi

        # 尝试从/sys/devices/system/node/获取NUMA信息
        if [ -d "/sys/devices/system/node" ]; then
            local numa_nodes=$(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)
            [ $numa_nodes -gt 0 ] && echo "NUMA节点数: $numa_nodes"
        fi

        # 尝试从/sys/class/dmi/id/获取内存类型和频率
        if [ -d "/sys/class/dmi/id" ]; then
            if [ -f "/sys/class/dmi/id/dmi_type" ]; then
                local mem_type=$(cat /sys/class/dmi/id/dmi_type 2>/dev/null | grep -i "DDR")
                [ ! -z "$mem_type" ] && echo "内存类型: $mem_type"
            fi
        fi

        # 尝试从/proc/bus/input/devices获取内存频率
        local mem_freq=$(cat /proc/bus/input/devices 2>/dev/null | grep -i "memory" | grep -o "[0-9]\+MHz" | head -n1)
        [ ! -z "$mem_freq" ] && echo "内存频率: $mem_freq"

        # 尝试从lshw获取内存插槽信息
        if command -v lshw &> /dev/null; then
            echo "\n内存条配置:"
            lshw -C memory 2>/dev/null | awk '/memory/,/\*-/' | grep -E "size:|clock:|description:" | while read line; do
                case "$line" in
                    *size:*)
                        size=$(echo $line | awk '{print $2$3}')
                        [ "$size" != "0B" ] && echo -n "$size "
                        ;;
                    *clock:*)
                        clock=$(echo $line | awk '{print $2"MHz"}')
                        [ "$clock" != "0MHz" ] && echo -n "@ $clock "
                        ;;
                    *description:*)
                        desc=$(echo $line | cut -d: -f2-)
                        [ ! -z "$desc" ] && echo "($desc)"
                        ;;
                esac
            done
        fi
        echo "----------------------------------------"
    fi
}

# 获取磁盘信息
get_disk() {
    echo -e "${YELLOW}磁盘信息:${NC}"
    echo -e "${GREEN}基本信息:${NC}"
    echo "========================================"
    
    # 创建一个函数来获取磁盘类型
    get_disk_type() {
        local disk=$1
        local type="未知"
        
        # 检查是否为NVMe设备
        if [[ -d "/sys/block/$disk/device/nvme" ]]; then
            local nvme_ver=$(cat /sys/block/$disk/device/nvme/transport 2>/dev/null)
            type="NVMe"
            [ ! -z "$nvme_ver" ] && type="$type ($nvme_ver)"
        # 检查是否为SATA/SAS设备
        elif [[ -d "/sys/block/$disk/device/sata_version" ]]; then
            local sata_ver=$(cat /sys/block/$disk/device/sata_version 2>/dev/null)
            type="SATA"
            [ ! -z "$sata_ver" ] && type="$type $sata_ver"
        # 检查是否为虚拟设备
        elif [[ -f "/sys/block/$disk/device/model" ]]; then
            local model=$(cat /sys/block/$disk/device/model 2>/dev/null)
            [[ "$model" == *"QEMU"* || "$model" == *"Virtual"* ]] && type="Virtual Disk"
        fi
        
        # 检查是否为SSD
        local rotational=$(cat /sys/block/$disk/queue/rotational 2>/dev/null)
        if [ "$rotational" = "0" ]; then
            [ "$type" = "未知" ] && type="SSD"
        elif [ "$rotational" = "1" ]; then
            [ "$type" = "未知" ] && type="HDD"
        fi
        
        echo "$type"
    }
    
    # 创建一个函数来获取磁盘速度
    get_disk_speed() {
        local disk=$1
        local speed=""
        
        # 检查NVMe速度
        if [[ -d "/sys/block/$disk/device/nvme" ]]; then
            local lanes=$(cat /sys/block/$disk/device/nvme/lanes 2>/dev/null)
            [ ! -z "$lanes" ] && speed="PCIe x$lanes"
        # 检查SATA速度
        elif [[ -f "/sys/block/$disk/device/sata_speed" ]]; then
            speed=$(cat /sys/block/$disk/device/sata_speed 2>/dev/null)
            [ ! -z "$speed" ] && speed="$speed Gb/s"
        fi
        
        echo "$speed"
    }
    
    # 显示磁盘信息
    printf "%-10s %-15s %-10s %-15s %s\n" "设备" "类型" "容量" "接口速度" "型号"
    echo "--------------------------------------------------------------------------------"
    
    # 获取所有块设备
    for disk in $(ls /sys/block/ 2>/dev/null | grep -E '^([hsv]d[a-z]|nvme[0-9]n[0-9]|mmcblk[0-9]|nbd[0-9]|sr[0-9])'); do
        # 跳过CD-ROM和临时设备
        if [[ $disk == loop* ]] || [[ $disk == ram* ]]; then
            continue
        fi
        
        # 获取磁盘信息
        local size=$(cat /sys/block/$disk/size 2>/dev/null)
        local model=$(cat /sys/block/$disk/device/model 2>/dev/null)
        [ -z "$model" ] && model="N/A"
        
        # 转换大小为人类可读格式
        if [ ! -z "$size" ]; then
            size=$((size * 512)) # 转换为字节
            size=$(awk -v bytes=$size 'BEGIN {
                if (bytes >= 1099511627776) printf "%.1fTB", bytes/1099511627776;
                else if (bytes >= 1073741824) printf "%.1fGB", bytes/1073741824;
                else printf "%.1fMB", bytes/1048576;
            }')
        else
            size="未知"
        fi
        
        # 获取类型和速度
        local type=$(get_disk_type $disk)
        local speed=$(get_disk_speed $disk)
        [ -z "$speed" ] && speed="N/A"
        
        # 打印信息
        printf "%-10s %-15s %-10s %-15s %s\n" "/dev/$disk" "$type" "$size" "$speed" "$model"
    done
    
    echo "\n注: 某些信息可能需要root权限才能获取完整显示"
}

# 获取GPU信息
get_gpu() {
    echo -e "${YELLOW}GPU信息:${NC}"
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi -L
    else
        echo -e "${RED}未检测到NVIDIA GPU或nvidia-smi命令不可用。${NC}"
        echo -e "${GREEN}尝试使用lspci查找其他GPU设备：${NC}"
        lspci | grep -i vga
    fi
}

# 转换字节为可读格式
format_bytes() {
    local bytes=$1
    awk -v bytes=$bytes 'BEGIN {
        if (bytes < 1024) printf "%.0fB", bytes;
        else if (bytes < 1048576) printf "%.2fKB", bytes/1024;
        else if (bytes < 1073741824) printf "%.2fMB", bytes/1048576;
        else printf "%.2fGB", bytes/1073741824;
    }'
}

# 计算网络带宽
calculate_bandwidth() {
    local interface=$1
    local old_rx=$2
    local old_tx=$3
    local interval=1
    
    sleep $interval
    local new_stats=$(cat /sys/class/net/$interface/statistics/rx_bytes /sys/class/net/$interface/statistics/tx_bytes)
    local new_rx=$(echo "$new_stats" | head -n1)
    local new_tx=$(echo "$new_stats" | tail -n1)
    
    local rx_bw=$(awk -v new=$new_rx -v old=$old_rx 'BEGIN {print (new - old)}')
    local tx_bw=$(awk -v new=$new_tx -v old=$old_tx 'BEGIN {print (new - old)}')
    
    echo "当前带宽："
    echo "下载: $(format_bytes $rx_bw)/s"
    echo "上传: $(format_bytes $tx_bw)/s"
}

# 获取网络接口信息
get_network() {
    echo -e "${YELLOW}网络接口信息:${NC}"
    if command -v ip &> /dev/null; then
        echo -e "${GREEN}接口地址信息:${NC}"
        echo "========================================"
        ip -br addr show
        echo "========================================"
        echo -e "${GREEN}接口流量统计:${NC}"
        echo "========================================"
        
        # 使用awk处理ip -s link的输出以获得更好的格式化显示
        ip -s link | awk '
        function format_bytes(bytes) {
            if (bytes < 1024) return bytes "B"
            else if (bytes < 1048576) return sprintf("%.2fKB", bytes/1024)
            else if (bytes < 1073741824) return sprintf("%.2fMB", bytes/1048576)
            else return sprintf("%.2fGB", bytes/1073741824)
        }
        /^[0-9]+:/ {
            if ($2 !~ /^lo/) {
                gsub(/:/, "");
                interface = $2;
                status = $3;
                for (i=4; i<=NF; i++) status = status " " $i;
                # 检查是否为Docker相关接口
                if (interface ~ /^docker/) {
                    printf "\n%s (Docker主网桥)\n", interface;
                } else if (interface ~ /^br-/) {
                    printf "\n%s (Docker自定义网桥)\n", interface;
                } else if (interface ~ /^veth/) {
                    printf "\n%s (Docker容器虚拟接口)\n", interface;
                } else {
                    printf "\n%s\n", interface;
                }
                printf "状态: %s\n", status;
                next;
            }
        }
        /RX:/ { rx=1; next; }
        /TX:/ { tx=1; next; }
        rx==1 {
            printf "接收: %s %s个包 %s个错误 %s个丢弃\n", format_bytes($1), $2, $3, $4;
            rx=0;
            next;
        }
        tx==1 {
            printf "发送: %s %s个包 %s个错误 %s个丢弃\n", format_bytes($1), $2, $3, $4;
            tx=0;
            next;
        }
        /RX:/ { rx=1; next; }
        /TX:/ { tx=1; next; }
        rx==1 {
            printf "接收: %s %s个包 %s个错误 %s个丢弃\n", format_bytes($1), $2, $3, $4;
            rx=0;
            next;
        }
        tx==1 {
            printf "发送: %s %s个包 %s个错误 %s个丢弃\n", format_bytes($1), $2, $3, $4;
            tx=0;
            next;
        }'
        echo "========================================"
        
        # 显示主要网络接口的实时带宽
        echo -e "${GREEN}实时网络带宽监控:${NC}"
        echo "========================================"
        for interface in $(ip -br link show | awk -F: '/^(e|w)/{print $1}'); do
            if [ -f "/sys/class/net/$interface/statistics/rx_bytes" ]; then
                echo -e "\n接口: $interface"
                old_stats=$(cat /sys/class/net/$interface/statistics/rx_bytes /sys/class/net/$interface/statistics/tx_bytes)
                old_rx=$(echo "$old_stats" | head -n1)
                old_tx=$(echo "$old_stats" | tail -n1)
                calculate_bandwidth "$interface" "$old_rx" "$old_tx"
            fi
        done
        echo "========================================"
    else
        echo -e "${GREEN}接口信息 (使用ifconfig):${NC}"
        echo "========================================"
        ifconfig | grep -E "^[a-zA-Z]|inet "
        echo "========================================"
    fi
}

# 获取系统负载
get_system_load() {
    echo -e "${YELLOW}系统负载:${NC}"
    uptime
    if [ -f "/proc/loadavg" ]; then
        echo -e "${GREEN}CPU负载:${NC} $(cat /proc/loadavg)"
        # 获取CPU使用率
        if [ -f "/proc/stat" ]; then
            local cpu_usage
            read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
            local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
            local idle_all=$((idle + iowait))
            local used=$((total - idle_all))
            cpu_usage=$(awk -v used=$used -v total=$total 'BEGIN {printf "%.2f", 100 * used / total}')
            echo -e "${GREEN}CPU使用率:${NC} ${cpu_usage}%"
        fi
    fi
}

# 获取温度信息
get_temperature() {
    echo -e "${YELLOW}温度信息:${NC}"
    if [ -d "/sys/class/thermal" ]; then
        for i in /sys/class/thermal/thermal_zone*; do
            if [ -f "$i/type" ] && [ -f "$i/temp" ]; then
                type=$(cat "$i/type")
                temp=$(awk '{printf "%.1f°C", $1/1000}' "$i/temp")
                echo "$type: $temp"
            fi
        done
    else
        echo -e "${RED}无法获取温度信息${NC}"
    fi
}

# 获取RAID状态
get_raid_status() {
    echo -e "${YELLOW}RAID状态:${NC}"
    if command -v mdadm &> /dev/null; then
        mdadm --detail --scan
        echo -e "${GREEN}RAID详细信息:${NC}"
        for raid in $(mdadm --detail --scan | awk '{print $2}'); do
            mdadm --detail "$raid"
        done
    elif [ -f "/proc/mdstat" ]; then
        cat /proc/mdstat
    else
        echo -e "${RED}未检测到RAID设备或无法获取RAID信息${NC}"
    fi
}

# 获取USB设备列表
get_usb_devices() {
    echo -e "${YELLOW}USB设备列表:${NC}"
    if command -v lsusb &> /dev/null; then
        lsusb
    else
        echo -e "${RED}lsusb命令不可用${NC}"
        if [ -d "/sys/bus/usb/devices/" ]; then
            for device in /sys/bus/usb/devices/*; do
                if [ -f "$device/product" ]; then
                    echo "$(cat "$device/product")"
                fi
            done
        fi
    fi
}

# 转换为JSON格式
to_json() {
    local output="{"
    output+="\"date\":\"$current_date\","
    output+="\"hostname\":\"$hostname\","
    
    # 添加其他信息
    for key in "${!json_data[@]}"; do
        output+="\"$key\":\"${json_data[$key]}\","
    done
    
    # 移除最后一个逗号并添加结束括号
    output="${output%,}"
    output+="}"
    echo "$output"
}

# 主函数
main() {
    if [ "$1" = "--json" ]; then
        JSON_OUTPUT=true
    fi

    if [ "$JSON_OUTPUT" = false ]; then
        echo -e "${YELLOW}==================== 服务器硬件信息报告 ====================${NC}"
        echo -e "${YELLOW}日期: $current_date${NC}"
        echo -e "${YELLOW}主机名: $hostname${NC}"
        echo -e "${YELLOW}============================================================${NC}"
    fi

    get_pm_info
    get_cpu
    get_mem
    get_disk
    get_gpu
    get_network
    get_system_load
    get_temperature
    get_raid_status
    get_usb_devices

    if [ "$JSON_OUTPUT" = true ]; then
        to_json
    fi
}

# 执行主函数并将输出保存到文件
main "$@" | tee /tmp/server-$(date +%F_%H-%M-%S).txt