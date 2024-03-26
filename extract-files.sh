#!/bin/bash
#
# Copyright (C) 2023 Paranoid Android
#
# SPDX-License-Identifier: Apache-2.0
#

set -e

### Setup
DUMP=
MY_DIR="${BASH_SOURCE%/*}"
SRC_ROOT="${MY_DIR}/../../.."
TMP_DIR=$(mktemp -d)
EXTRACT_KERNEL=true
declare -a MODULE_FOLDERS=("vendor_ramdisk" "vendor_dlkm" "system_dlkm")
declare -a DTBO_PANEL_PATCHES=(
    "fuxi:dsi_m3_38_0c_0a_dsc_cmd"
    "fuxi:dsi_m3gl_38_0c_0a_dsc_cmd"
    "nuwa:dsi_m2_38_0c_0a_dsc_cmd"
    "nuwa:dsi_m2a_42_02_0b_dsc_cmd"
)

while [ "${#}" -gt 0 ]; do
    case "${1}" in
        -n | --no-kernel )
                EXTRACT_KERNEL=false
                ;;
        * )
                DUMP="${1}"
                ;;
    esac
    shift
done

[ -f "${MY_DIR}/Module.symvers" ] || touch "${MY_DIR}/Module.symvers"
[ -f "${MY_DIR}/System.map" ] || touch "${MY_DIR}/System.map"

# Check if dump is specified and exists
if [ -z "${DUMP}" ]; then
    echo "Please specify the dump!"
    exit 1
elif [ ! -d "${DUMP}" ]; then
    echo "Unable to find dump at ${DUMP}!"
    exit 1
fi

echo "Extracting files from ${DUMP}:"

### Kernel
if ${EXTRACT_KERNEL}; then
    echo "Extracting boot image.."
    ${SRC_ROOT}/system/tools/mkbootimg/unpack_bootimg.py \
        --boot_img "${DUMP}/boot.img" \
        --out "${TMP_DIR}/boot.out" > /dev/null
    cp -f "${TMP_DIR}/boot.out/kernel" ${MY_DIR}/Image
    echo "  - Image"
fi

### DTBS
# Cleanup / Preparation
rm -rf "${MY_DIR}/dtbs"
mkdir "${MY_DIR}/dtbs"

echo "Extracting vendor_boot image..."
${SRC_ROOT}/system/tools/mkbootimg/unpack_bootimg.py \
    --boot_img "${DUMP}/vendor_boot.img" \
    --out "${TMP_DIR}/vendor_boot.out" > /dev/null

curl -sSL "https://raw.githubusercontent.com/PabloCastellano/extract-dtb/master/extract_dtb/extract_dtb.py" > ${TMP_DIR}/extract_dtb.py

# Copy
python3 "${TMP_DIR}/extract_dtb.py" "${TMP_DIR}/vendor_boot.out/dtb" -o "${TMP_DIR}/dtbs" > /dev/null
find "${TMP_DIR}/dtbs" -type f -name "*.dtb" \
    -exec cp {} "${MY_DIR}/dtbs" \; \
    -exec printf "  - dtbs/" \; \
    -exec basename {} \;

python3 "${TMP_DIR}/extract_dtb.py" "${DUMP}/dtbo.img" -o "${TMP_DIR}/dtbo" > /dev/null
for DTBO_PANEL_PATCH in "${DTBO_PANEL_PATCHES[@]}"; do
    DTBO_PANEL_PATCH=(${DTBO_PANEL_PATCH//:/ })
    device=${DTBO_PANEL_PATCH[0]}
    panel=${DTBO_PANEL_PATCH[1]}
    find "${TMP_DIR}/dtbo" -type f -name "*${device}*.dtb" -exec grep -q "${panel}" {} \; \
        -exec bash -c '
            dt_node="$(fdtget -t s "{}" /__symbols__ "'${panel}'")";
            panel_height="$(fdtget -t i "{}" $dt_node "qcom,mdss-pan-physical-height-dimension")";
            panel_width="$(fdtget -t i "{}" $dt_node "qcom,mdss-pan-physical-width-dimension")";
            fdtput -t li "{}" "$dt_node" qcom,mdss-pan-physical-height-dimension "$((panel_height / 10))";
            fdtput -t li "{}" "$dt_node" qcom,mdss-pan-physical-width-dimension "$((panel_width / 10))";
        ' \; \
        -exec printf "    + Fixed up panel dimensions of ${panel} in dtbo/" \; \
        -exec basename {} \;
done
${SRC_ROOT}/system/libufdt/utils/src/mkdtboimg.py \
    create "${MY_DIR}/dtbs/dtbo.img" --page_size=4096 "${TMP_DIR}/dtbo/"*.dtb
echo "    + Generated dtbs/dtbo.img"

### Modules
# Cleanup / Preparation
for MODULE_FOLDER in "${MODULE_FOLDERS[@]}"; do
    rm -rf "${MY_DIR}/${MODULE_FOLDER}"
    mkdir "${MY_DIR}/${MODULE_FOLDER}"
done

# Copy
for MODULE_FOLDER in "${MODULE_FOLDERS[@]}"; do
    MODULE_SRC="${DUMP}/${MODULE_FOLDER}"
    if [ "${MODULE_FOLDER}" == "vendor_ramdisk" ]; then
        lz4 -qd "${TMP_DIR}/vendor_boot.out/vendor_ramdisk00" "${TMP_DIR}/vendor_ramdisk.cpio"
        7z x "${TMP_DIR}/vendor_ramdisk.cpio" -o"${TMP_DIR}/vendor_ramdisk" > /dev/null
        MODULE_SRC="${TMP_DIR}/vendor_ramdisk"
    fi
    [ -d "${MODULE_SRC}" ] || break
    find "${MODULE_SRC}/lib/modules" -type f \
        -exec cp {} "${MY_DIR}/${MODULE_FOLDER}/" \; \
        -exec printf "  - ${MODULE_FOLDER}/" \; \
        -exec basename {} \;
done

# Clear temp dir
rm -rf "${TMP_DIR}"
