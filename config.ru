require 'rubygems'
require 'bundler'

Bundler.require

require './treasures'
run Sinatra::Application
