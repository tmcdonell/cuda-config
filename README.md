cuda-config
===========

[![Travis build status](https://img.shields.io/travis/tmcdonell/cuda-config/master.svg?label=linux)](https://travis-ci.org/tmcdonell/cuda-config)
[![Stackage LTS](https://stackage.org/package/cuda-config/badge/lts)](https://stackage.org/lts/package/cuda-config)
[![Stackage Nightly](https://stackage.org/package/cuda-config/badge/nightly)](https://stackage.org/nightly/package/cuda-config)
[![Hackage](https://img.shields.io/hackage/v/cuda-config.svg)](https://hackage.haskell.org/package/cuda-config)

Determine the installation location of CUDA and generate appropriate
configuration options for Cabal.

This will look for your CUDA installation in the standard places, and if the
`nvcc` compiler is found in your `PATH`, relative to that.

Instructions for installing the CUDA development kit can be found here:

  <http://developer.nvidia.com/object/cuda.html>

