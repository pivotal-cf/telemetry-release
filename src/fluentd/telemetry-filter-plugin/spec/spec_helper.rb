$LOAD_PATH.unshift(File.expand_path('..', __dir__))
require 'rspec'
require 'fluent/test'
require 'fluent/test/helpers'
require 'fluent/test/driver/filter'

# prevent Test::Unit's AutoRunner from executing
Test::Unit.run = true
