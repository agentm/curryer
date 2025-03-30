# v0.4.0 (2025-03-29)

* add ability to serve and connect to IPv6 and Unix domain sockets (#5)

# v0.3.8 (2024-12-20)

* add support for winery 1.5 but don't require it

# v0.3.7 (2024-08-24)

* enable building with GHC 9.6, 9.8, 9.10
	
# v0.3.6 (2024-07-20)

* update to streamly 0.10.1
* update to streamly-bytestring 0.2.2 which includes a critical fix related to pinned arrays used within streamly

# v0.3.5 (2024-01-12)

* disable extraneous debug logging

# v0.3.4 (2024-01-12)

* revert to streamly 0.9.0 due to corruption bug in streamly-0.10.0

# v0.3.3 (2024-01-07)

* use streamly 0.10.0 and streamly-core 0.2.0

# v0.3.2 (2023-12-30)

* enable support for GHC 9.4

# v0.3.1 (2023-10-30)

* enable TCP_NODELAY to reduce intermessage latency

# v0.3.0 (2023-04-01)

* require streamly 0.9.0+

# v0.2.2 (2022-08-17)

* add support for GHC 9.2
	
# v0.2.1 (2021-12-28)

* bump up streamly dependency to 0.8.1 due to streamly internals API change since 0.8.0

# v0.2 (2021-12-13)

* update for streamly 0.8.0 (we are no longer pegged to a pre-release streamly)

# v0.1 (2020-12-27)

* initial release to support [Project:M36](https://github.com/agentm/project-m36)
	
