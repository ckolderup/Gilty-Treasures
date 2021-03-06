require 'sinatra'
require 'data_mapper'
require 'haml'
require 'json'
require 'net/http'
require 'net/https'
require 'gilt'
require 'atom'

GILT_API_KEY = ENV['GILT_API_KEY'] || ''

class NoProductError < RuntimeError
end

DataMapper.setup(:default, ENV['DATABASE_URL'] || "sqlite://#{Dir.pwd}/treasures.db")

class Product
  include DataMapper::Resource
  property :id, Serial
  property :name, Text
  property :description, Text
  property :price, Decimal, :precision => 10, :scale => 2
  property :date, Date, :unique => true
  property :image_url, Text
  property :url, Text

  def self.before(date)
    self.first(:date.lt => date, :order => [ :date.desc ])
  end

  def self.after(date)
    self.first(:date.gt => date, :order => [ :date.asc ])
  end

  def self.top5
    self.all(:limit => 5, :order => [ :price.desc ])
  end
end

DataMapper.auto_upgrade!

get '/' do
  d = DateTime.now
  d = d - 1 if (d.hour < 12)
  redirect "/#{d.year}/#{d.month}/#{d.day}"
end

get '/top' do
  @top = Product.top5
  haml :top
end

def date_is_latest?(date)
  date === Date.today && DateTime.now.hour >= 12 ||
  date === Date.today - 1 && DateTime.now.hour <= 12
end

def date_in_past?(date)
  date < Date.today
end

def fetch_product(date)
  puts "fetching products..."
  sales = Gilt::Sale.active :apikey => GILT_API_KEY
  todays_sales = sales.select {|sale| sale.begins.to_date === date }
  products = todays_sales.collect{|sale| sale.products}.flatten
  sorted_products = products.sort do |a,b|
    b.max_price <=> a.max_price
  end
  chosen = sorted_products.first
  image_url = chosen.images['420x560'].first['url']
  @p = Product.create(:name => chosen.name,
                      :description => chosen.description,
                      :price => chosen.max_price, :image_url => image_url,
                      :url => chosen.url, :date => date)
end

get '/:year/:month/:day' do
  begin
    date = DateTime.new(params[:year].to_i, params[:month].to_i, params[:day].to_i)
  rescue
    error 404
  end

  @p = Product.first(:date => DateTime.new(date.year, date.month, date.day))
  @prev = Product.before(date)
  @next = Product.after(date)

  fetch_product(date) if @p.nil? && date_is_latest?(date)

  begin
    if date_is_latest?(date)
      raise NoProductError, "Error fetching product for today. Try again later." if @p.nil?
      haml :one
    elsif date_in_past?(date)
      raise NoProductError, "No data collected for this day." if @p.nil?
      haml :one
    else
      raise NoProductError, "You can't look into the future, silly!"
    end
  rescue NoProductError
    @error = $!
    haml :none
  end
end

get '/atom' do
  products = Product.all(:limit => 10, :order => [ :date.desc ])
  updated = DateTime.new(products.first.date.year, products.first.date.month, products.first.date.day, 12)
  feed_id = "tag:giltytreasures.heroku.com,2012:sale:feed"
  feed = Atom::Feed.new do |f|
    f.title = "Gilty Treasures"
    f.links << Atom::Link.new(:href => "http://gilty-treasures.heroku.com", :rel => "alt")
    f.links << Atom::Link.new(:href => "http://gilty-treasures.heroku.com/atom", :rel => "self")
    f.id = feed_id
    f.updated = updated
    f.authors << Atom::Person.new(:name => "Casey Kolderup", :email => "casey@kolderup.org")
    products.each do |product|
      f.entries << Atom::Entry.new do |e|
        e.title = product.name
        e.links << Atom::Link.new(:href =>
           "http://gilty-treasures.heroku.com/#{product.date.year}/#{product.date.month}/#{product.date.day}")
        e.updated = DateTime.new(product.date.year, product.date.month, product.date.day, 12)
        e.id = "#{feed_id}-#{product.id}"
        e.summary = "FOR SALE: #{product.name} ($%.2f)" % product.price
      end
    end
  end
  feed.to_xml
end
