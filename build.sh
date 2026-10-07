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
                                build-essential binutils perl liblzma-dev mtools git rustup
                                gcc-x86-64-linux-gnu gcc-i686-linux-gnu 
                                gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf
                                gcc-riscv64-linux-gnu gcc-loongarch64-linux-gnu
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
                # "dnf")
                #         pkgs=(
                #                 make gcc binutils glibc-devel.i686 perl xz-devel mtools git rustup
                #                 gcc-x86_64-linux-gnu gcc-aarch64-linux-gnu gcc-arm-linux-gnu
                #                 gcc-riscv64-linux-gnu gcc-loongarch64-linux-gnu
                #         )
                #         ${priv:-} dnf install -y "${pkgs[@]}"
                #         ;;
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

	for i in gcc as ld ar objcopy objdump ranlib nm make perl git nproc; do
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

main() {
        detect_deps
        "${HAS_HARD_REQS}" || {
                install_deps
                detect_deps
        }

        "${HAS_HARD_REQS}" || {
                echo -e "\n${R}Missing iPXE build dependencies:${N}"
                printf "  ${R}- %s${N}\n" "${MISSING_DEPS[@]}"
                exit 1
        }

        clone_ipxe
        build_ipxe

        # cd "${MPO_XAV}"

        # loginf b "Building mpo-xav!"

        # logfile="/tmp/build_cargo_$.log"
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
