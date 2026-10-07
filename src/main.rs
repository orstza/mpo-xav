mod tftp;

pub fn main() -> std::io::Result<()> {
    let bind_addr = "127.0.0.1:6969";
    println!("Starting TFTP server on {}", bind_addr);
    tftp::serve_tftp(bind_addr)
}