Synthetic `nvidia-smi nvlink -e` fixtures, one per generation. NVLink 1 through
4 use the documented legacy Replay/Recovery/CRC counters. NVLink 5 uses
receive, discard, integrity, recovery and FEC counters. Traffic and BER fields
are deliberate negative cases. These are parser fixtures, not hardware captures.

Labels: https://docs.nvidia.com/deploy/nvidia-smi/index.html (NVLink error counters).
