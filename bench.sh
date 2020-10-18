cabal run perf -- +RTS -p && ~/.cabal/bin/ghc-prof-flamegraph < perf.prof > perf.html
