use super::*;
use hangar_spice::encode;

#[test]
fn a_host_that_stopped_reading_fails_the_send_instead_of_piling_up() -> io::Result<()> {
    let (release, write_waits) = mpsc::channel::<()>();
    let (taken, first_taken) = mpsc::channel::<()>();
    let writer = HostWriter::start(move |_bytes| {
        let _told = taken.send(());
        let _released = write_waits.recv();
        Ok(())
    })?;

    // The first message is in the stuck write before the rest line up, so the last one never
    // finds the room it would have while the writer is still taking the first.
    writer.send(&spice::hello())?;
    first_taken
        .recv()
        .map_err(|_gone| io::Error::other("the writer never started"))?;
    let sends: Vec<io::Result<()>> = (0..=WAITING_MESSAGES)
        .map(|_| writer.send(&spice::hello()))
        .collect();
    drop(release);

    let failure = sends.last().and_then(|sent| sent.as_ref().err());
    assert_eq!(
        failure.map(ToString::to_string),
        Some("the host stopped reading".to_string())
    );
    Ok(())
}

#[test]
fn a_replaced_connection_is_stale() {
    let mut link = Link::default();
    let first = link.connect();
    let second = link.connect();
    let hello = hangar_spice::hello();

    assert_eq!(link.reply(first, &hello), None);
    assert!(link.reply(second, &hello).is_some());

    assert!(!link.close(first));
    assert!(link.is_connected());

    assert!(link.close(second));
    assert!(!link.is_connected());
    assert_eq!(link.reply(second, &hello), None);
    assert_eq!(link.guest_copied(), None);
    assert_ne!(link.connect(), second);
}

#[test]
fn the_reader_delivers_messages_then_closes() {
    let bytes = encode(&hangar_spice::hello());
    let mut events = Vec::new();

    read_host_messages(bytes.as_slice(), EmptyRead::Closed, |event| {
        events.push(event);
    });

    let [HostEvent::Messages(messages), HostEvent::Closed] = events.as_slice() else {
        panic!("{events:?}");
    };
    assert_eq!(messages.len(), 1);
}

/// Never has bytes; notes when it is dropped, which closes a real port.
struct SilentPort(Arc<AtomicBool>);

impl Read for SilentPort {
    fn read(&mut self, _buffer: &mut [u8]) -> io::Result<usize> {
        Ok(0)
    }
}

impl Drop for SilentPort {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

#[test]
fn a_reader_stopped_while_waiting_lets_go_of_the_port_before_it_reports_closed() {
    let dropped = Arc::new(AtomicBool::new(false));
    let stop = Arc::new(AtomicBool::new(false));
    let stop_while_waiting = Arc::clone(&stop);
    let port = StoppablePort {
        port: SilentPort(Arc::clone(&dropped)),
        stop,
        wait: move |_: &SilentPort| {
            stop_while_waiting.store(true, Ordering::Relaxed);
            Ok(false)
        },
    };
    let mut dropped_when_closed = None;

    read_host_messages(port, EmptyRead::NotYet, |event| {
        if let HostEvent::Closed = event {
            dropped_when_closed = Some(dropped.load(Ordering::Relaxed));
        }
    });

    assert_eq!(dropped_when_closed, Some(true));
}

#[test]
fn a_ready_port_is_still_read() {
    let bytes = encode(&hangar_spice::hello());
    let port = StoppablePort {
        port: bytes.as_slice(),
        stop: Arc::new(AtomicBool::new(false)),
        wait: |_: &&[u8]| Ok(true),
    };
    let mut events = Vec::new();

    read_host_messages(port, EmptyRead::Closed, |event| events.push(event));

    assert!(matches!(
        events.as_slice(),
        [HostEvent::Messages(_), HostEvent::Closed]
    ));
}
