#!/bin/bash

# Function to create systemd service
create_service() {
    local service_file="/etc/systemd/system/auto-vm.service"
    
    if [ -f "$service_file" ]; then
        echo "[*] Existing auto-vm service found. Updating..."
        sudo systemctl stop auto-vm.service
    fi

    echo "[*] Creating systemd service for automatic VM management..."
    
    cat << EOF | sudo tee "$service_file" > /dev/null
[Unit]
Description=Auto VM Service
After=network.target

[Service]
Type=forking
ExecStart=$PWD/$0 --start-vm
ExecStop=$PWD/$0 --stop-vm
RemainAfterExit=yes
User=$USER
Group=$USER

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable auto-vm.service
    echo "[*] Service created and enabled. It will start automatically on boot."
}

# Function to start the VM
start_vm() {
    echo "[*] Starting VM through systemd service..."
    
    # Check if VM is already running
    if pgrep -f "qemu-system-x86_64" > /dev/null; then
        echo "[*] VM is already running."
        return
    fi

    echo "[*] Updating packages and installing essentials..." 
    sudo apt update && sudo apt install -y qemu-kvm unzip cpulimit python3-pip qemu-utils qemu-system-x86 alsa-utils pulseaudio \
    libvirt-daemon-system libvirt-clients bridge-utils virt-manager spice-vdagent ovmf virtiofsd \
    qemu-audio-pulseaudio qemu-audio-alsa qemu-block-extra qemu-efi net-tools xterm git curl novnc websockify

    if [ $? -ne 0 ]; then 
        echo "[!] Error installing packages. Please check and retry." 
        exit 1 
    fi

    # Check and mount /mnt if not mounted
    echo "[] Checking /mnt mount..." 
    if ! mount | grep -q "on /mnt "; then 
        echo "[] Searching for unmounted >500GB partition..." 
        partition=$(lsblk -b -o NAME,SIZE,MOUNTPOINT | awk '$2 > 500000000000 && $3 == "" {print $1}' | head -n 1) 
        if [ -n "$partition" ]; then 
            echo "[*] Mounting /dev/$partition..." 
            sudo mount "/dev/${partition}1" /mnt || { echo "[!] Failed to mount."; exit 1; } 
        else 
            echo "[!] No suitable partition found." 
            exit 1 
        fi 
    fi

    # Select OS
    echo "Select VM OS:" 
    echo "1. Windows 11 23H2" 
    echo "2. Ubuntu 22.04 LTS" 
    echo "3. Windows 11 24H2" 
    echo "4. UEFI 4 Windows OS" 
    read -p "Choice: " user_choice

    if [ "$user_choice" -eq 1 ]; then 
        file_url="https://api.cloud.hashicorp.com/vagrant-archivist/v1/object/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJrZXkiOiIyMWZlYWNmYi0xMWY5LT" 
    elif [ "$user_choice" -eq 2 ]; then 
        file_url="https://api.cloud.hashicorp.com/vagrant-archivist/v1/object/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJrZXkiOiI1ZGQ1NmM1OC04ZDQ4LTQ0Nz" 
    elif [ "$user_choice" -eq 3 ]; then 
        file_url="https://api.cloud.hashicorp.com/vagrant-archivist/v1/object/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJrZXkiOiJsaW51eHVzZXJzZmFrZS9XaW" 
    elif [ "$user_choice" -eq 4 ]; then 
        file_url="https://www.dropbox.com/scl/fi/cm4kqg5f5iis40bzmy7yo/windualboot.qcow2?...&dl=1" 
    else 
        echo "[!] Invalid option." 
        exit 1 
    fi

    file_name="/mnt/a.qcow2" 
    echo "[*] Downloading VM image..." 
    wget -O "$file_name" "$file_url" || { echo "[!] Download failed."; exit 1; }

    # Launch QEMU VM with optimization
    echo "[*] Launching optimized QEMU VM..."

    sudo cpulimit -l 90 -- sudo qemu-system-x86_64 \
    -machine q35,accel=kvm,usb=on \
    -cpu host,+topoext,+aes,+ssse3,+sse4.2,hv_relaxed,hv_spinlocks=0x1fff,kvm=on,+svm \
    -smp 4,sockets=1,cores=2,threads=2 \
    -m 6144 \
    -rtc base=localtime,clock=host \
    -enable-kvm \
    -vga virtio \
    -device virtio-gpu-pci \
    -device usb-tablet \
    -device virtio-rng-pci \
    -device virtio-balloon-pci \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::3389-:3389 \
    -audiodev pa,id=snd0,out.frequency=44100,in.frequency=44100,out.channels=2,in.channels=2 \
    -device ich9-intel-hda -device hda-output,audiodev=snd0 \
    -drive file="$file_name",format=qcow2,if=virtio \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/ovmf/OVMF.fd \
    -boot c \
    -uuid e47ddb84-fb4d-46f9-b531-14bb15156336 \
    -vnc :0 \
    -no-shutdown -no-reboot &

    sleep 5

    # Launch noVNC for browser access
    echo "[*] Starting noVNC on http://localhost:6080 ..." 
    websockify --web=/usr/share/novnc/ 6080 localhost:5900 &>/dev/null &

    echo "[] VM started! Access via browser: http://localhost:6080" 
    echo "[] RDP also available at port 3389 (if enabled in guest OS)"
    
    # Save PID to file for later shutdown
    pgrep -f "qemu-system-x86_64" | sudo tee /var/run/auto-vm.pid > /dev/null
}

# Function to stop the VM
stop_vm() {
    echo "[*] Stopping VM..."
    
    if [ -f "/var/run/auto-vm.pid" ]; then
        pid=$(cat /var/run/auto-vm.pid)
        if ps -p "$pid" > /dev/null; then
            sudo kill "$pid"
            echo "[*] VM process stopped."
        else
            echo "[*] VM process not found."
        fi
        sudo rm -f /var/run/auto-vm.pid
    else
        echo "[*] No running VM found."
    fi
    
    # Also stop noVNC
    pkill -f "websockify" && echo "[*] noVNC stopped."
}

# Main command handling
case "$1" in
    "--install-service")
        create_service
        ;;
    "--start-vm")
        start_vm
        ;;
    "--stop-vm")
        stop_vm
        ;;
    "--uninstall-service")
        sudo systemctl stop auto-vm.service
        sudo systemctl disable auto-vm.service
        sudo rm -f /etc/systemd/system/auto-vm.service
        sudo systemctl daemon-reload
        echo "[*] Service uninstalled."
        ;;
    *)
        # Interactive mode
        echo "Auto VM Management Script"
        echo "Usage options:"
        echo "  --install-service    : Install as systemd service for auto-start"
        echo "  --start-vm           : Start the VM manually"
        echo "  --stop-vm            : Stop the VM manually"
        echo "  --uninstall-service  : Remove the systemd service"
        echo ""
        echo "Running in interactive mode..."
        
        PS3='Please choose an option: '
        options=("Install as auto-start service" "Start VM now" "Stop VM now" "Uninstall auto-start service" "Quit")
        select opt in "${options[@]}"
        do
            case $opt in
                "Install as auto-start service")
                    create_service
                    ;;
                "Start VM now")
                    start_vm
                    ;;
                "Stop VM now")
                    stop_vm
                    ;;
                "Uninstall auto-start service")
                    sudo systemctl stop auto-vm.service
                    sudo systemctl disable auto-vm.service
                    sudo rm -f /etc/systemd/system/auto-vm.service
                    sudo systemctl daemon-reload
                    echo "[*] Service uninstalled."
                    ;;
                "Quit")
                    break
                    ;;
                *) echo "Invalid option $REPLY";;
            esac
        done
        ;;
esac
