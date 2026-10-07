use std::net::{SocketAddr, UdpSocket};
use std::thread;
use std::time::Duration;

macro_rules! ipxe_target {
    ($rel:expr) => {
        include_bytes!(concat!("../ipxeboot", $rel))
    };
}

const IPXE_BIOS_KPXE: &[u8] = ipxe_target!("/x86_64/undionly.kpxe");
const IPXE_X86_64_EFI: &[u8] = ipxe_target!("/x86_64/ipxe.efi");
const IPXE_I386_EFI: &[u8] = ipxe_target!("/i386/ipxe.efi");
const IPXE_ARM64_EFI: &[u8] = ipxe_target!("/arm64/ipxe.efi");
const IPXE_ARM32_EFI: &[u8] = ipxe_target!("/arm32/ipxe.efi");
const IPXE_RISCV64_EFI: &[u8] = ipxe_target!("/riscv64/ipxe.efi");
const IPXE_LOONG64_EFI: &[u8] = ipxe_target!("/loong64/ipxe.efi");

const TFTP_RRQ: u16 = 1;
const TFTP_DATA: u16 = 3;
const TFTP_ACK: u16 = 4;
const TFTP_ERROR: u16 = 5;

const TFTP_BLOCK_SIZE: usize = 512;
const TFTP_HEADER_SIZE: usize = 4;
const TFTP_PACKET_SIZE: usize = TFTP_HEADER_SIZE + TFTP_BLOCK_SIZE;

const TFTP_RETRIES: usize = 4;
const TFTP_TIMEOUT: Duration = Duration::from_millis(500);

fn image_for(filename: &str) -> Option<&'static [u8]> {
    match filename {
        "x86_64/undionly.kpxe" => Some(IPXE_BIOS_KPXE),
        "x86_64/ipxe.efi" => Some(IPXE_X86_64_EFI),
        "i386/ipxe.efi" => Some(IPXE_I386_EFI),
        "arm64/ipxe.efi" => Some(IPXE_ARM64_EFI),
        "arm32/ipxe.efi" => Some(IPXE_ARM32_EFI),
        "riscv64/ipxe.efi" => Some(IPXE_RISCV64_EFI),
        "loong64/ipxe.efi" => Some(IPXE_LOONG64_EFI),
        _ => None,
    }
}

fn rrq_filename(packet: &[u8]) -> Option<&str> {
    if packet.len() < 4 || packet[..2] != TFTP_RRQ.to_be_bytes() {
        return None;
    }

    let rest = &packet[2..];

    let name_end = rest.iter().position(|&b| b == 0)?;
    let mode = &rest[name_end + 1..];

    // Require the mode to be NUL-terminated as well.
    if !mode.contains(&0) {
        return None;
    }

    std::str::from_utf8(&rest[..name_end])
        .ok()
        .map(|s| s.trim_start_matches('/'))
}

fn send_error(socket: &UdpSocket, client: SocketAddr, message: &[u8]) -> std::io::Result<()> {
    let mut packet = [0u8; 128];

    let len = TFTP_HEADER_SIZE + message.len() + 1;
    if len > packet.len() {
        return Ok(());
    }

    packet[..2].copy_from_slice(&TFTP_ERROR.to_be_bytes());
    packet[2..4].copy_from_slice(&1u16.to_be_bytes()); // File not found
    packet[4..4 + message.len()].copy_from_slice(message);

    socket.send_to(&packet[..len], client)?;
    Ok(())
}

fn send_block(
    socket: &UdpSocket,
    tx_packet: &mut [u8; TFTP_PACKET_SIZE],
    ack_buf: &mut [u8; 4],
    payload: &[u8],
    block: u16,
) -> std::io::Result<()> {
    tx_packet[..2].copy_from_slice(&TFTP_DATA.to_be_bytes());
    tx_packet[2..4].copy_from_slice(&block.to_be_bytes());
    tx_packet[4..4 + payload.len()].copy_from_slice(payload);

    let packet = &tx_packet[..TFTP_HEADER_SIZE + payload.len()];

    for _ in 0..TFTP_RETRIES {
        socket.send(packet)?;

        loop {
            match socket.recv(ack_buf) {
                Ok(4)
                    if ack_buf[..2] == TFTP_ACK.to_be_bytes()
                        && u16::from_be_bytes([ack_buf[2], ack_buf[3]]) == block =>
                {
                    return Ok(());
                }

                Ok(_) => {
                    // Ignore malformed or unrelated packets and keep waiting.
                    // This suck as it doesn't handle Opcode 5: Error.
                }

                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                    ) =>
                {
                    break;
                }

                Err(e) => return Err(e),
            }
        }
    }

    Err(std::io::Error::new(
        std::io::ErrorKind::TimedOut,
        "TFTP transfer timed out",
    ))
}

// TFTP (RFC 1350)
fn transfer_worker(client: SocketAddr, data: &[u8]) -> std::io::Result<()> {
    let bind_addr = if client.is_ipv6() {
        "[::]:0"
    } else {
        "0.0.0.0:0"
    };

    let socket = UdpSocket::bind(bind_addr)?;
    socket.connect(client)?;
    socket.set_read_timeout(Some(TFTP_TIMEOUT))?;

    let mut tx_packet = [0u8; TFTP_PACKET_SIZE];
    let mut ack_buf = [0u8; 4];
    let mut block = 1u16;

    for chunk in data.chunks(TFTP_BLOCK_SIZE) {
        send_block(&socket, &mut tx_packet, &mut ack_buf, chunk, block)?;

        block = block.wrapping_add(1);
    }

    // A zero-length DATA packet terminates transfers whose size
    // is an exact multiple of the block size.
    if data.len() % TFTP_BLOCK_SIZE == 0 {
        send_block(&socket, &mut tx_packet, &mut ack_buf, &[], block)?;
    }

    Ok(())
}

pub fn serve_tftp(bind_addr: &str) -> std::io::Result<()> {
    let main_socket = UdpSocket::bind(bind_addr)?;
    let mut rx_buf = [0u8; 1024];

    loop {
        let (len, client) = main_socket.recv_from(&mut rx_buf)?;

        let Some(filename) = rrq_filename(&rx_buf[..len]) else {
            continue;
        };

        let Some(payload) = image_for(filename) else {
            eprintln!("Unknown file requested: '{filename}'");
            let _ = send_error(&main_socket, client, b"File not found");
            continue;
        };

        thread::Builder::new()
            .stack_size(64 * 1024)
            .spawn(move || {
                if let Err(e) = transfer_worker(client, payload) {
                    eprintln!("TFTP transfer to {client} failed: {e}");
                }
            })?;
    }
}
