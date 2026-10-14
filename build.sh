#!/usr/bin/env bash

((BASH_VERSINFO[0] >= 5)) || {
        echo "You need Bash 5+."
        exit 1
}

set -Eeuo pipefail

install_deps() {
        ((UID != 0)) && { for i in sudo doas; do command -v "${i}" > /dev/null 2>&1 && priv="${i}"; done; }

        pm="unknown"
        for i in pacman dnf apt emerge; do command -v "${i}" > /dev/null 2>&1 && pm="${i}"; done

        case "${pm}" in
                "apt")
                        pkgs=(
                                git rustup
                                # ipxe build & corss-compile dependencies
                                build-essential binutils perl liblzma-dev mtools 
                                gcc-x86-64-linux-gnu gcc-i686-linux-gnu 
                                gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf
                                gcc-riscv64-linux-gnu gcc-loongarch64-linux-gnu
                                # mkosi dependencies
                                python3 python3-venv python3-pefile python3-cryptography # python and zipapp
                                cpio kmod zstd xz-utils # kernel & initrd assembly
                                systemd systemd-ukify systemd-boot-efi systemd-boot-tools # boot & uki generation
                                systemd-repart fdisk dosfstools mtools e2fsprogs btrfs-progs erofs-utils # disk & partitioning
                                dnf distribution-gpg-keys gnupg # fedora bootstrap
                                uidmap # rootless sandbox
                                qemu-system ovmf ipxe-qemu virtiofsd # VM for mkosi development
                        )
                        ${priv:-} apt update && ${priv:-} apt install -y "${pkgs[@]}"
                        ;;
                # "pacman")
                #         pkgs=(
                #                 base-devel lib32-glibc perl xz mtools git rustup
                #                 aarch64-linux-gnu-gcc riscv64-linux-gnu-gcc
                #                 loongarch64-linux-gnu-gcc
                #         )
                #         needed=$(pacman -T "${pkgs[@]}") || ${priv:-} pacman -S --needed --noconfirm ${needed}
                #         ;;
                "dnf")
                        pkgs=(
                                git rustup
                                # ipxe build & corss-compilation dependencies
		                make gcc binutils glibc-devel.i686 perl xz-devel mtools
		                gcc-x86_64-linux-gnu gcc-arm-linux-gnu gcc-aarch64-linux-gnu
		                gcc-riscv64-linux-gnu gcc-loongarch64-linux-gnu
                                # mkosi dependencies
                                python3 python3-pefile python3-cryptography # python and zipapp
		                cpio kmod zstd xz # kernel & initrd assembly
		                systemd systemd-ukify systemd-boot-unsigned systemd-container # boot & uki generation
		                util-linux dosfstools e2fsprogs btrfs-progs erofs-utils # disk & partitioning
		                dnf distribution-gpg-keys gnupg2 # fedora bootstrap
                                shadow-utils # rootless sandbox
                                qemu-system-x86 edk2-ovmf ipxe-roms-qemu virtiofsd # VM for mkosi development
                        )
                        ${priv:-} dnf install -y "${pkgs[@]}"
                        ;;
                "emerge")
                        echo "You need sys-devel/gcc sys-devel/binutils sys-devel/make"
                        echo "dev-lang/perl app-arch/xz-utils sys-fs/mtools dev-vcs/git"
                        echo "dev-lang/rustup and cross-compilers for x86, aarch64, arm, riscv64 and loongarch64"
                        ;;
                *)
                        echo "ERROR: You need GCC, binutils, Make, Perl, liblzma/xz, mtools, Rust, and target cross-GCC toolchains."
                        ;;
        esac

        command -v rustup > /dev/null 2>&1 && {
                rustup-init -y --no-modify-path || true
                rustup update
        }
}

BUILD_DIR="${HOME}/.local/src"
mkdir -p "${BUILD_DIR}"
MPO_XAV="$(pwd)"

R='\e[1;91m' B='\e[1;94m' P='\e[1;95m' Y='\e[1;93m'
N='\033[0m' C='\e[1;96m' G='\e[1;92m' W='\e[1;97m'

loginf() {
        sleep "0.1"

        case "${1}" in
                g) COL="${G}" MSG="DONE!" ;;
                r) COL="${R}" MSG="ERROR!" ;;
                b) COL="${B}" MSG="STARTING." ;;
                c) COL="${B}" MSG="RUNNING." ;;
        esac

        RAWMSG="${2}"
        DATE="$(date "+%Y-%m-%d ${C}/${P} %H:%M:%S")"
        LOG="${C}[${P}${DATE}${C}] ${Y}>>>${COL}${MSG}${Y}<<< - ${COL}${RAWMSG}${N}"

        [[ "${1}" == "c" ]] && echo -e "\n\n${LOG}" || echo -e "${LOG}"
}

handle_err() {
        local exit_code="${?}"
        local failed_command="${BASH_COMMAND}"
        local failed_line="${BASH_LINENO[0]}"

        trap - ERR INT

        [[ "${exit_code}" -eq 130 ]] && {
                echo -e "\n${R}Interrupted by user${N}"
                exit 130
        }

        loginf r "Line ${B}${failed_line}${R}: cmd ${B}'${failed_command}'${R} exited with ${B}\"${exit_code}\""

        [[ -f "${logfile:-}" ]] && {
                echo -e "\n${R}Output:${N}\n"
                cat "${logfile}"
        }

        exit "${exit_code}"
}

handle_int() {
        echo -e "\n${R}Interrupted by user${N}"
        exit 130
}

trap 'handle_err' ERR
trap 'handle_int' INT
trap 'kill $(jobs -p) 2> /dev/null || true' EXIT

find_bin() {
        command -v "${1}" 2> /dev/null
}

clone_ipxe() {
        [[ -d "${BUILD_DIR}/ipxe/.git" ]] && return

        loginf b "Cloning iPXE into ${BUILD_DIR}/ipxe"
        git clone --depth 1 https://github.com/ipxe/ipxe.git "${BUILD_DIR}/ipxe"
        loginf g "iPXE clone ready"
}

# Minimum mkosi version 26, which most distros doesn't have yet.
clone_mkosi() {
        [[ -d "${BUILD_DIR}/mkosi/.git" ]] && return
        loginf b "Cloning mkosi into ${BUILD_DIR}/mkosi"
        git clone --depth 1 --branch v27.1 https://github.com/systemd/mkosi.git "${BUILD_DIR}/mkosi"
        loginf g "mkosi clone ready"
}

verify_target() {
	local prefix="${1}"
	local flags="${2}"
	local condition="${3}"

	for i in gcc as ld ar objcopy objdump; do
		command -v "${prefix}${i}" >/dev/null || return 1
	done

        # iPXE requires GNU BFD ld, not GNU gold linker.
        if "${prefix}ld" -v 2>&1 | grep -q 'GNU gold'; then
                return 1
        fi

	printf '#if !(%s)\n#error mismatch\n#endif\n' "${condition}" |
	"${prefix}gcc" ${flags} -x c -c -o /dev/null - 2> /dev/null
}

resolve_toolchain() {
	local condition="${1}"
	local multilib_flag="${2}"
	shift 2

	# 1. Native compiler
	verify_target "" "" "${condition}" && return 0

	# 2. Native multilib
	[ -n "${multilib_flag}" ] && verify_target "" "${multilib_flag}" "${condition}" && return 0

	# 3. Dedicated cross-toolchains
	local prefix
	for prefix in "${@}"; do
		verify_target "${prefix}" "" "${condition}" && {
			echo "${prefix}"
			return 0
		}
	done

	return 1
}

detect_deps() {
	HAS_HARD_REQS=true
	MISSING_DEPS=()

	for i in \
                gcc as ld ar objcopy objdump ranlib nm make perl git nproc python3 \
                cpio depmod zstd xz \
		systemctl ukify bootctl systemd-repart \
		sfdisk mkfs.fat mcopy mkfs.ext4 mkfs.btrfs mkfs.erofs \
		dnf gpg newuidmap newgidmap; do
		[ -n "$(find_bin "${i}")" ] || {
			HAS_HARD_REQS=false
			MISSING_DEPS+=("${i}")
		}
	done

	printf '#include <lzma.h>\nint main(void) { return lzma_version_number() == 0; }\n' |
	gcc -x c - -llzma -o /dev/null > /dev/null 2>&1 || {
		HAS_HARD_REQS=false
		MISSING_DEPS+=("liblzma/xz")
	}

	X86_64_CROSS="$(resolve_toolchain 'defined(__x86_64__)' '' x86_64-linux-gnu- x86_64-pc-linux-gnu-)" || {
		HAS_HARD_REQS=false
		MISSING_DEPS+=("x86_64 toolchain")
	}

	I386_CROSS="$(resolve_toolchain 'defined(__i386__)' '-m32' i686-linux-gnu- i386-linux-gnu-)" || {
		HAS_HARD_REQS=false
		MISSING_DEPS+=("i386 toolchain")
	}

	AARCH64_CROSS="$(resolve_toolchain 'defined(__aarch64__)' '' aarch64-linux-gnu-)" || {
		HAS_HARD_REQS=false
		MISSING_DEPS+=("aarch64 toolchain")
	}

	ARM32_CROSS="$(resolve_toolchain 'defined(__arm__)' '' arm-linux-gnueabihf- arm-linux-gnu-)" || {
		HAS_HARD_REQS=false
		MISSING_DEPS+=("ARM32 toolchain")
	}

	RISCV64_CROSS="$(resolve_toolchain 'defined(__riscv) && __riscv_xlen == 64' '' riscv64-linux-gnu-)" || {
		HAS_HARD_REQS=false
		MISSING_DEPS+=("riscv64 toolchain")
	}

	LOONGARCH64_CROSS="$(resolve_toolchain 'defined(__loongarch64)' '' loongarch64-linux-gnu-)" || {
		HAS_HARD_REQS=false
		MISSING_DEPS+=("loongarch64 toolchain")
	}

        [ -n "$(find_bin virtiofsd)" ] || [ -x /usr/libexec/virtiofsd ] || [ -x /usr/lib/virtiofsd ] || {
		HAS_HARD_REQS=false
		MISSING_DEPS+=("virtiofsd")
	}

        for mod in venv pefile cryptography; do
		python3 -c "import ${mod}" > /dev/null 2>&1 || {
			HAS_HARD_REQS=false
			MISSING_DEPS+=("python3-${mod}")
		}
	done

        compgen -G "/usr/lib/systemd/boot/efi/*.efi.stub" > /dev/null || {
		HAS_HARD_REQS=false
		MISSING_DEPS+=("systemd-boot-efi")
	}

	[ -d /usr/share/distribution-gpg-keys ] || {
		HAS_HARD_REQS=false
		MISSING_DEPS+=("distribution-gpg-keys")
	}

        # [ -f /usr/share/ovmf/OVMF.fd ] || [ -f /usr/share/edk2/ovmf/OVMF_CODE.fd ] || {
	# 	HAS_HARD_REQS=false
	# 	MISSING_DEPS+=("ovmf")
	# }

	# [ -d /usr/lib/ipxe/qemu ] || [ -d /usr/share/ipxe/qemu ] || {
	# 	HAS_HARD_REQS=false
	# 	MISSING_DEPS+=("ipxe-qemu")
	# }

        # for arch in x86_64 i386 aarch64 arm riscv64 loongarch64; do
	# 	[ -n "$(find_bin "qemu-system-${arch}")" ] || {
	# 		HAS_HARD_REQS=false
	# 		MISSING_DEPS+=("qemu-system-${arch}")
	# 	}
	# done
}

build_ipxe_target() {
        local target="${1}"
        local dest="${2}"
        local logfile="/tmp/build_ipxe_$$.log"
        : > "${logfile}"
        shift 2

        loginf b "Building ${target}"
        make -C "${BUILD_DIR}/ipxe/src" -j"$(nproc)" "${target}" EMBED="${BUILD_DIR}/ipxe/embed.ipxe" "${@}" >> "${logfile}" 2>&1
        mkdir -p "$(dirname "${MPO_XAV}/ipxeboot/${dest}")"
        cp "${BUILD_DIR}/ipxe/src/${target}" "${MPO_XAV}/ipxeboot/${dest}" && {
                rm -f "${logfile}"
                loginf g "${target} built successfully"
        } || {
                echo -e "\n${R}Build failed! Output:${N}\n"
                cat "${logfile}"
                rm -f "${logfile}"
                exit 1
        }
}

build_ipxe() {
        loginf b "Building iPXE"

        cat <<- 'EOF' > "${BUILD_DIR}/ipxe/embed.ipxe"
#!ipxe
set gpus
:pci_loop
pciscan dev && goto pci_check || goto pci_done

:pci_check
iseq ${dev/0x0b:hex8} 03 || goto pci_loop

set gpus ${gpus}&gpu=${dev/vendor:hex16}:${dev/device:hex16}
goto pci_loop

:pci_done
chain http://${next-server}/ipxesend?buildarch=${buildarch}&platform=${platform}&uuid=${uuid}&chip=${netX/chip}&mac=${netX/mac}&ip=${netX/ip}${gpus}
EOF
        sed -i 's/#define BANNER_TIMEOUT.*/#define BANNER_TIMEOUT 0/' ${BUILD_DIR}/ipxe/src/config/general.h

        # --- x86 Targets ---
        build_ipxe_target "bin-x86_64-pcbios/undionly.kpxe" "x86_64/undionly.kpxe" \
                CROSS_COMPILE="${X86_64_CROSS}"
        build_ipxe_target "bin-x86_64-efi/ipxe.efi"         "x86_64/ipxe.efi" \
                CROSS_COMPILE="${X86_64_CROSS}"
        build_ipxe_target "bin-i386-efi/ipxe.efi"           "i386/ipxe.efi" \
                CROSS_COMPILE="${I386_CROSS}"

        # --- ARM Targets ---
        build_ipxe_target "bin-arm64-efi/ipxe.efi"          "arm64/ipxe.efi" \
                CROSS_COMPILE="${AARCH64_CROSS}"
        build_ipxe_target "bin-arm32-efi/ipxe.efi"          "arm32/ipxe.efi" \
                CROSS_COMPILE="${ARM32_CROSS}"

        # --- RISC-V Target ---
        build_ipxe_target "bin-riscv64-efi/ipxe.efi"        "riscv64/ipxe.efi" \
                CROSS_COMPILE="${RISCV64_CROSS}"

        # --- LoongArch Target ---
        build_ipxe_target "bin-loong64-efi/ipxe.efi"        "loong64/ipxe.efi" \
                CROSS_COMPILE="${LOONGARCH64_CROSS}"

        loginf g "All iPXE architecture targets generated in ${MPO_XAV}/ipxeboot"
}

build_mkosi() {
        loginf b "Building mkosi"

        local logfile="/tmp/build_mkosi_$$.log"
        : > "${logfile}"

        cd "${BUILD_DIR}/mkosi"  
        tools/generate-zipapp.sh >> "${logfile}" 2>&1
        builddir/mkosi --version >> "${logfile}" 2>&1

        cp "${BUILD_DIR}/mkosi/builddir/mkosi" "${MPO_XAV}/mkosi_lab" >> "${logfile}" 2>&1 && {
                rm -f "${logfile}"
                loginf g "mkosi built successfully"
        } || {
                echo -e "\n${R}Build failed! Output:${N}\n"
                cat "${logfile}"
                rm -f "${logfile}"
                exit 1
        }
}

main() {
        detect_deps
        "${HAS_HARD_REQS}" || {
                install_deps
                detect_deps
        }

        "${HAS_HARD_REQS}" || {
                echo -e "\n${R}Missing build dependencies:${N}"
                printf "  ${R}- %s${N}\n" "${MISSING_DEPS[@]}"
                exit 1
        }

        clone_ipxe
        build_ipxe

        clone_mkosi
        build_mkosi

        # cd "${MPO_XAV}"

        # loginf b "Building mpo-xav!"

        # logfile="/tmp/build_cargo_$$.log"
        # : > "${logfile}"

        # export IPXE_DIR="${BUILD_DIR}/ipxe/src"

        # cargo build --release --config .cargo/config.toml.static >> "${logfile}" 2>&1 && {
        #         rm -f "${logfile}"
        #         loginf g "Rust static build complete"
        # } || {
        #         echo -e "\n${R}Build failed! Output:${N}\n"
        #         cat "${logfile}"
        #         rm -f "${logfile}"
        #         exit 1
        # }
}

main
