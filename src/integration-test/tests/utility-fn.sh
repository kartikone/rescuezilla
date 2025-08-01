# Directory containing this build script
INTEGRATION_TEST_FOLDER=$(dirname $(readlink -f "$0"))/../

# Get IP
TARGET_IP=`./integration_test.py listip --vm $VM`

run_cmd_in_rescuezilla_vm() {
    TARGET_IP="$1"
    RUN_CMD_IN_VM="$2"

    # Note: Production builds of Rescuezilla do not have openssh-server installed (or a pre-authorized SSH key configured with ssh-copy-id)

    SSH_SERVER="ubuntu@$TARGET_IP"
    ssh-keygen -R $TARGET_IP
    # Copy a script to detect if the machine is a VirtualBox VM, and also to mount the VirtualBox shared folder
    scp -o "CheckHostIP=no" -o "StrictHostKeyChecking=no" "scripts/configure-virtualbox-vm.sh" $SSH_SERVER:/tmp/
    # DANGER: Run a command within the VM. The command could be eg, restoring a backup on to /dev/sda, which can be very dangerous.
    # Notice there are two key protections against accidentally overwriting the wrong SSH server: it is connecting as the ubuntu user
    # with a pretrusted SSH key, and the careful syntax which first checks for whether the machine the command is being run on is a VM.
    ssh -o "CheckHostIP=no" -o "StrictHostKeyChecking=no" -t $SSH_SERVER "/tmp/configure-virtualbox-vm.sh && sudo $RUN_CMD_IN_VM"
    if [ $? -ne 0 ]; then
        echo "** Test failed"
        exit 1
    fi
}

# Boot Rescuezilla
boot_dvd() {
     VM="$1"
     ISO_PATH="${2:-$INTEGRATION_TEST_FOLDER/../../build/rescuezilla.amd64.jammy.iso}"
     ISO_CHECK_MATCH="${3:-Ubuntu 22.04}"
     ./integration_test.py stop --vm $VM
     sleep 1
     ./integration_test.py insertdvd --vm $VM --path-to-dvd "$ISO_PATH"

     echo "** HACK: Temporary disconnect virtual HD from VM to workaround VirtualBox bug where systems configured as EFI don't respect boot order"
     echo "** HACK: so always boot from HD rather than optical media [1] (doesn't happen on BIOS systems but use same detach logic for simplicity)"
     echo "** HACK: It's expected for VirtualBox to say 'The machine is not mutable (state is Running)'"
     echo "** [1] https://www.virtualbox.org/ticket/19364"
     ./integration_test.py detachhd --vm $VM
     ./integration_test.py start --vm $VM
     if [ $? -ne 0 ]; then
        echo "** Failed to start VM: $VM"
        exit 1
     fi

     echo "** HACK: Reattach HD after booting from DVD after a short sleep, as a workaround for the VirtualBox EFI boot order bug described above"
     sleep 10
     ./integration_test.py attachhd --vm $VM

     # Check to confirm Rescuezilla environment is online
     ./integration_test.py check --vm $VM --contains "$ISO_CHECK_MATCH"
     # It takes time for the Ubuntu user account to be generated
     # TODO: Improve this solution
     sleep 5
}

check_primary_os_boots() {
    VM="$1"
    VM_CHECK_MATCH="$2"
    ./integration_test.py stop --vm $VM
    sleep 1
    ./integration_test.py removedvd --vm $VM
    if [ $? -ne 0 ]; then
        echo "** Could not remove DVD."
        return 1
    fi
    ./integration_test.py start --vm $VM
    ./integration_test.py check --vm $VM --contains "$VM_CHECK_MATCH"
    CHECK_STATUS=$?
    ./integration_test.py stop --vm $VM
    return $CHECK_STATUS
}

_launch_backup_with_rescuezilla_cli() {
    TARGET_IP="$1"
    IMAGE_NAME="$2"
    IMAGE_PATH="/mnt/rescuezilla.shared.folder/$IMAGE_NAME"

    echo "* Creating backup image using Rescuezilla CLI"
    run_cmd_in_rescuezilla_vm "$TARGET_IP" " \
    echo \"** Delete previous Rescuezilla image from within the VM $IMAGE_PATH\" && \
    cd /mnt/rescuezilla.shared.folder && sudo rm -rf $IMAGE_NAME && \
    echo \"Deliberately use low compression to speed up operations (while still testing primary processing pipeline)\" && \
    time sudo rescuezillapy backup --compression-format=gzip --compression-level=0 --source /dev/sda --destination $IMAGE_PATH \
    "
}

_launch_restore_with_rescuezilla_cli() {
    TARGET_IP="$1"
    IMAGE_NAME="$2"
    IMAGE_PATH="/mnt/rescuezilla.shared.folder/$IMAGE_NAME"

    time run_cmd_in_rescuezilla_vm $TARGET_IP "rescuezillapy restore --source $IMAGE_PATH --destination /dev/sda"
}

_launch_backup_with_clonezilla_cli() {
    TARGET_IP="$1"
    IMAGE_NAME="$2"
    IMAGE_PATH="/mnt/rescuezilla.shared.folder/$IMAGE_NAME"

    echo "* Creating backup image using Clonezilla CLI"
    run_cmd_in_rescuezilla_vm $TARGET_IP "\
    echo \"** Delete previous Clonezilla image from within the VM $IMAGE_PATH\" && \
    cd /mnt/rescuezilla.shared.folder && sudo rm -rf $IMAGE_NAME && \
    echo \"Modify Clonezilla config file in-place to enable pigz usage WITHOUT compression rather, to match Rescuezilla config. Note: standard gzip does not offer compression level zero\" && \
    echo \"Also deliberately not using no-compression pathway so testing realistic executable and data pipeline pathway\" && \
    sudo sed --in-place 's|^extra_pigz_opt=\"--fast |extra_pigz_opt=\"-0 |g' /etc/drbl/drbl-ocs.conf && \
    echo \"--batch mode to suppress warning about partition size larger than 2 TiB requiring GPT format\" && \
    ocs_live_batch=yes && time sudo /usr/sbin/ocs-sr --nogui --batch -q2 -j2 -z1p -i 4096 -sfsck -senc -p command savedisk $IMAGE_NAME sda
    "
}

_launch_restore_with_clonezilla_cli() {
    TARGET_IP="$1"
    IMAGE_NAME="$2"
    # Command adapted running Clonezilla restoredisk in Beginner mode using default settings
    # --batch mode to suppress "which is larger than the MBR partition table entry maximum 2 TiB (~ 2.2 TB). You have to use GUID partition table format (GPT)."
    CLONEZILLA_COMMAND="ocs-sr --nogui --batch -g auto -e1 auto -e2 -r -j2 -scr restoredisk $IMAGE_NAME sda"
    time run_cmd_in_rescuezilla_vm $TARGET_IP "$CLONEZILLA_COMMAND"
}

_stop_vm_reset_disk_and_boot_dvd() {
    VM_NAME="$1"
    ISO_PATH="$2"
    ISO_CHECK_MATCH="$3"

    ./integration_test.py stop --vm $VM_NAME
    sleep 1
    ./integration_test.py reset --vm $VM_NAME
    boot_dvd "$VM_NAME" "$ISO_PATH" "$ISO_CHECK_MATCH"
}

_print_summary() {
    SUCCESS=$1
    VM_INFO=$2
    EXTRA_INFO=$3
    EXIT_ON_FAILURE=$4

    if [ $SUCCESS -eq 0 ]; then
        echo "::notice Test success: $VM_INFO -- $EXTRA_INFO"
        echo ""
    else
        echo "::error Test failed: $VM_INFO -- $EXTRA_INFO"
        echo ""
        if $EXIT_ON_FAILURE; then
             exit $SUCCESS
        fi
    fi
}

test_init() {
    VM_NAME="$1"
    PRIMARY_OS_CHECK_MATCH="$2"
    VM_INFO="$3"

    echo "* Redeploy primary OS"
    ./integration_test.py stop --vm $VM_NAME
    sleep 1
    ./integration_test.py reset --vm $VM_NAME
    ./integration_test.py deploy --vm $VM_NAME
    echo "* Sanity check primary OS boots, and correctly configured for integration test to confirm"
    check_primary_os_boots "$VM_NAME" "$PRIMARY_OS_CHECK_MATCH"
    _print_summary $? "$VM_INFO" "Sanity check primary OS configuration before doing any operation" true
}

restore_with_rescuezilla_cli() {
    VM_NAME="$1"
    ISO_PATH="$2"
    ISO_CHECK_MATCH="$3"
    TARGET_IP="$4"
    IMAGE_NAME="$5"
    PRIMARY_OS_CHECK_MATCH="$6"
    VM_INFO="$7"
    EXIT_ON_FAILURE="$8"

    echo "* Testing restore of $IMAGE_NAME with Rescuezilla CLI"
    _stop_vm_reset_disk_and_boot_dvd "$VM_NAME" "$ISO_PATH" "$ISO_CHECK_MATCH" false
    _launch_restore_with_rescuezilla_cli "$TARGET_IP" "$IMAGE_NAME"
    check_primary_os_boots "$VM_NAME" "$PRIMARY_OS_CHECK_MATCH"
    _print_summary $? "$VM_INFO" "Restore attempt of $IMAGE_NAME using Rescuezilla CLI" $EXIT_ON_FAILURE
}

restore_with_clonezilla_cli() {
    VM_NAME="$1"
    ISO_PATH="$2"
    ISO_CHECK_MATCH="$3"
    TARGET_IP="$4"
    IMAGE_NAME="$5"
    PRIMARY_OS_CHECK_MATCH="$6"
    VM_INFO="$7"
    EXIT_ON_FAILURE="$8"

    echo "* Testing restore of $IMAGE_NAME with Clonezilla CLI"
    _stop_vm_reset_disk_and_boot_dvd "$VM_NAME" "$ISO_PATH" "$ISO_CHECK_MATCH" false
    _launch_restore_with_clonezilla_cli "$TARGET_IP" "$IMAGE_NAME"
    check_primary_os_boots "$VM_NAME" "$PRIMARY_OS_CHECK_MATCH"
    _print_summary $? "$VM_INFO" "Restore attempt of $IMAGE_NAME using Clonezilla CLI" $EXIT_ON_FAILURE
}

backup_restore_test() {
    TEST_PREFIX="$1"
    VM_NAME="$2"
    ISO_PATH="$3"
    ISO_CHECK_MATCH="$4"
    PRIMARY_OS_CHECK_MATCH="$5"

    RESCUEZILLA_IMAGE_NAME="Rescuezilla.$TEST_PREFIX.Image"
    CLONEZILLA_IMAGE_NAME="Clonezilla.$TEST_PREFIX.Image"

    TARGET_IP=`./integration_test.py listip --vm $VM_NAME`

    VM_INFO="\"$VM_NAME\" ($CLONEZILLA_IMAGE_NAME and $RESCUEZILLA_IMAGE_NAME) with boot check: \"$PRIMARY_OS_CHECK_MATCH\""
    echo "* Starting backup/restore test for $VM_INFO"

    test_init "$VM_NAME" "$PRIMARY_OS_CHECK_MATCH" "$VM_INFO"

    echo "* Boot into Rescuezilla DVD to begin tests"
    boot_dvd "$VM_NAME" "$ISO_PATH" "$ISO_CHECK_MATCH"

    _launch_backup_with_rescuezilla_cli "$TARGET_IP" "$RESCUEZILLA_IMAGE_NAME"
    _launch_backup_with_clonezilla_cli "$TARGET_IP" "$CLONEZILLA_IMAGE_NAME"

    restore_with_rescuezilla_cli "$VM_NAME" "$ISO_PATH" "$ISO_CHECK_MATCH" "$TARGET_IP" "$RESCUEZILLA_IMAGE_NAME" "$PRIMARY_OS_CHECK_MATCH" "$VM_INFO" "true"
    restore_with_rescuezilla_cli "$VM_NAME" "$ISO_PATH" "$ISO_CHECK_MATCH" "$TARGET_IP" "$CLONEZILLA_IMAGE_NAME" "$PRIMARY_OS_CHECK_MATCH" "$VM_INFO" "true"

    restore_with_clonezilla_cli "$VM_NAME" "$ISO_PATH" "$ISO_CHECK_MATCH" "$TARGET_IP" "$RESCUEZILLA_IMAGE_NAME" "$PRIMARY_OS_CHECK_MATCH" "$VM_INFO" "true"
    restore_with_clonezilla_cli "$VM_NAME" "$ISO_PATH" "$ISO_CHECK_MATCH" "$TARGET_IP" "$CLONEZILLA_IMAGE_NAME" "$PRIMARY_OS_CHECK_MATCH" "$VM_INFO" "false"
}
