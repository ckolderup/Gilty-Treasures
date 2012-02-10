require 'sinatra'
require 'data_mapper'
require 'haml'
require 'json'
require 'net/http'
require 'net/https'

GILT_API_KEY = ENV['GILT_API_KEY'] || ''
API_DOMAIN = 'https://api.gilt.com'
SALES_URL = "#{API_DOMAIN}/v1/sales/active.json?apikey=#{GILT_API_KEY}"

class NoProductError < RuntimeError
end

class Gilt
  def self.max(date)
    sales = get_sales(date)
    products = products_for_sales(sales)
    product = biggest_product(products, date)
  end

  private
  def self.fetch(url)
    puts "fetching #{url}..."
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)
    if (response.code != "200") then
      raise "Response #{response.code}"
    else
      JSON.parse(response.body)
    end
  end

  def self.get_sales(date)
    sales = fetch(SALES_URL)["sales"]
    sales.delete_if do |sale|
      begins = DateTime.parse(sale["begins"])
      Date.new(begins.year, begins.month, begins.day) != date
    end
  end

  def self.products_for_sales(sales)
    products = []
    sales.each do |sale|
      next if sale["products"].nil?
      sale["products"].each { |url| products << fetch("#{url}?apikey=#{GILT_API_KEY}") }
    end
    products
  end

  def self.biggest_product(products, date)
    pick_product, pick_price = nil, 0
    products.each do |product|
      high_price = highest_sku_price(product)
      if (high_price > pick_price) then
        pick_product = product
        pick_product['price'] = high_price
        pick_price = high_price 
      end
    end
    pick_product
  end

  def self.highest_sku_price(product)
    highest = 0
    product['skus'].each do |sku|
      sale_price = sku['sale_price'].to_d
      highest = sale_price if sale_price > highest
    end
    highest
  end
end

def product_before(date)
  Product.first(:date.lt => date, :order => [ :date.desc ])
end

def product_after(date)
  Product.first(:date.gt => date, :order => [ :date.asc ])
end

def top5
  Product.all(:limit => 5, :order => [ :price.desc ])
end

DataMapper.setup(:default, ENV['DATABASE_URL'] || "sqlite://#{Dir.pwd}/treasures.db")

class Product
  include DataMapper::Resource
  property :id, Serial
  property :name, Text
  property :description, Text
  property :price, Decimal
  property :date, Date, :unique => true
  property :image_url, Text
  property :url, Text

  def self.fromMap(obj, date)
    image_url = obj['image_urls']['420x560'].first['url']
    url = obj['url']
    Product.create(:name => obj['name'],
                   :description => obj['description'],
                   :price => obj['price'],
                   :image_url => image_url,
                   :url => url, :date => date)
  end
end

DataMapper.auto_upgrade!

get '/' do
  d = DateTime.now
  d = d - 1 if (d.hour < 12)
  redirect "/#{d.year}/#{d.month}/#{d.day}"
end

get '/top' do
  @top = top5
  haml :top
end

get '/:year/:month/:day' do
  begin
    d = DateTime.new(params[:year].to_i, params[:month].to_i, params[:day].to_i)
  rescue
    error 404
  end
  
  @p = Product.first(:date => d)

  begin 
    if (d === Date.today && DateTime.now.hour >= 12 || 
        d === Date.today - 1 && DateTime.now.hour <= 12) then
      if (@p.nil?) then
        @p = Product.fromMap(Gilt.max(d), d)
      end
      raise NoProductError, "Error fetching product for today. Try again later." if @p.nil?
      @prev = product_before(@p.date)
      @next = product_after(@p.date)
      haml :one
    elsif (d < Date.today) then
      raise NoProductError, "No data collected for this day." if @p.nil?
      @prev = product_before(@p.date)
      @next = product_after(@p.date)
      haml :one
    else
      raise NoProductError, "You can't look into the future, silly!"
    end
  rescue NoProductError
    @error = $!
    haml :none
  end
end
