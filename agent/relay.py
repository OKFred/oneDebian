#!/usr/bin/env python3
"""Relay ordinary-user stdio to one configured loopback service, without logging payloads."""
import contextlib
import os
import selectors
import signal
import socket
import sys
import termios
import time
import tty

from runtime import settings

BUFFER_SIZE = 16 * 1024
HEARTBEAT_SECONDS = 5
READY = b'ONEDEBIAN_RELAY_READY\n'
SERVICES = {'viewer':'viewer_port', 'mcp':'mcp_port'}


class Cancelled(Exception):
    pass


class HostClosed(Exception):
    pass


def notice(message, required=False):
    try:
        written = os.write(2,message)
        if required and written != len(message):
            raise HostClosed()
    except BlockingIOError:
        if required:
            raise HostClosed()
    except OSError:
        raise HostClosed() from None


@contextlib.contextmanager
def raw_stdio():
    modes = []; terminals = []
    try:
        for descriptor in (0,1,2):
            modes.append((descriptor,os.get_blocking(descriptor)))
            os.set_blocking(descriptor,False)
        for descriptor in (0,1):
            if os.isatty(descriptor):
                terminals.append((descriptor,termios.tcgetattr(descriptor)))
                tty.setraw(descriptor,when=termios.TCSANOW)
        yield
    finally:
        for descriptor,attributes in reversed(terminals):
            with contextlib.suppress(OSError):
                termios.tcsetattr(descriptor,termios.TCSANOW,attributes)
        for descriptor,blocking in reversed(modes):
            with contextlib.suppress(OSError):
                os.set_blocking(descriptor,blocking)


def interest(poller, descriptor, events, label):
    try:
        current = poller.get_key(descriptor)
    except KeyError:
        if events:
            poller.register(descriptor,events,label)
    else:
        if not events:
            poller.unregister(descriptor)
        elif events != current.events:
            poller.modify(descriptor,events,label)


def pump(backend):
    incoming = bytearray(); outgoing = bytearray()
    stdin_open = read_open = write_open = True
    next_heartbeat = time.monotonic() + HEARTBEAT_SECONDS
    with raw_stdio(), selectors.PollSelector() as poller:
        notice(READY,required=True)
        while read_open or outgoing:
            if not stdin_open and not incoming and write_open:
                with contextlib.suppress(OSError):
                    backend.shutdown(socket.SHUT_WR)
                write_open = False
            interest(poller,0,selectors.EVENT_READ if stdin_open and write_open and len(incoming) < BUFFER_SIZE else 0,'stdin')
            interest(poller,1,selectors.EVENT_WRITE if outgoing else 0,'stdout')
            events = (selectors.EVENT_READ if read_open and len(outgoing) < BUFFER_SIZE else 0)
            if write_open and incoming:
                events |= selectors.EVENT_WRITE
            interest(poller,backend,events,'backend')
            for key,ready in poller.select(max(0,next_heartbeat-time.monotonic())):
                try:
                    if key.data == 'stdin':
                        data = os.read(0,BUFFER_SIZE-len(incoming))
                        if data:
                            incoming.extend(data)
                        else:
                            stdin_open = False
                    elif key.data == 'stdout':
                        written = os.write(1,outgoing)
                        del outgoing[:written]
                    else:
                        if ready & selectors.EVENT_WRITE and incoming:
                            written = backend.send(incoming)
                            del incoming[:written]
                        if ready & selectors.EVENT_READ and read_open:
                            data = backend.recv(BUFFER_SIZE-len(outgoing))
                            if data:
                                outgoing.extend(data)
                            else:
                                read_open = stdin_open = False
                except (BlockingIOError,InterruptedError):
                    continue
            if time.monotonic() >= next_heartbeat:
                # A dead host may leave an idle SSE socket open; stderr detects that without timing out live traffic.
                notice(b'\n')
                next_heartbeat = time.monotonic() + HEARTBEAT_SECONDS


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    if len(arguments) != 1 or arguments[0] not in SERVICES:
        with contextlib.suppress(HostClosed):
            notice(b'ONEDEBIAN_RELAY_ERROR choose-viewer-or-mcp\n')
        return 2
    try:
        if os.getuid() == 0 or os.geteuid() != os.getuid():
            raise RuntimeError()
        config = settings()
        port = config[SERVICES[arguments[0]]]
        if type(port) is not int or not 1024 <= port <= 65535:
            raise ValueError()
    except (RuntimeError,ValueError,OSError,KeyError,TypeError):
        with contextlib.suppress(HostClosed):
            notice(b'ONEDEBIAN_RELAY_ERROR configuration\n')
        return 2
    previous = {}
    def cancel(signum,_frame):
        raise Cancelled(signum)
    try:
        for signum in (signal.SIGTERM,signal.SIGINT):
            previous[signum] = signal.signal(signum,cancel)
        with socket.socket(socket.AF_INET,socket.SOCK_STREAM) as backend:
            backend.settimeout(5)
            try:
                backend.connect(('127.0.0.1',port))
            except OSError:
                with contextlib.suppress(HostClosed):
                    notice(b'ONEDEBIAN_RELAY_ERROR backend-unavailable\n')
                return 3
            backend.setblocking(False)
            pump(backend)
        return 0
    except HostClosed:
        return 0
    except Cancelled as error:
        return 128 + error.args[0]
    except OSError:
        with contextlib.suppress(HostClosed):
            notice(b'ONEDEBIAN_RELAY_ERROR stream-closed\n')
        return 1
    finally:
        for signum,handler in previous.items():
            signal.signal(signum,handler)


if __name__ == '__main__':
    raise SystemExit(main())
