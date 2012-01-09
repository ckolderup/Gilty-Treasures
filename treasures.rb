require 'sinatra'
require 'data_mapper'
require 'haml'
require 'json'
require 'net/http'
require 'net/https'

GILT_API_KEY = ENV['GILT_API_KEY'] || ''
API_DOMAIN = 'https://api.gilt.com'
QUERY_URL = "#{API_DOMAIN}/v1/sales/active.json?product_detail=true&apikey=#{GILT_API_KEY}"

def fetch_sales(url)
  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  request = Net::HTTP::Get.new(uri.request_uri)
  response = http.request(request)
  if (response.code != "200") then
    raise "Response #{response.code}"
  else
    return JSON.parse(response.body)
  end
end

def find_product_and_price(sales, date)
  pick_product, pick_price = nil, 0
  sales.each do |sale|
    next if sale['products'].nil?
    begins = DateTime.parse(sale['begins'])
    next unless Date.new(begins.year, begins.month, begins.day) === date
    sale['products'].each do |product|
      high_price = highest_sku_price(product)
      if (high_price > pick_price) then
        pick_product = product
        pick_price = high_price 
      end
    end
  end
  [pick_product, pick_price]
end

def highest_sku_price(product)
  highest = 0
  product['skus'].each do |sku|
    sale_price = sku['sale_price'].to_d
    highest = sale_price if sale_price > highest
  end
  highest
end

DataMapper.setup(:default, ENV['DATABASE_URL'] || "sqlite://#{Dir.pwd}/treasures.db")

class Product
  include DataMapper::Resource
  property :id, Serial
  property :name, Text
  property :description, Text
  property :price, Decimal
  property :date, Date
  property :image_url, Text
end

DataMapper.auto_upgrade!

get '/' do
  t = Date.today
  redirect "/#{t.year}/#{t.month}/#{t.day}"
end

get '/:year/:month/:day' do
  begin
    d = Date.new(params[:year].to_i, params[:month].to_i, params[:day].to_i)
  rescue
    error 404
  end

  @p = Product.first(:date => d)

  if @p.nil?
    if (d === Date.today)
      product, price = find_product_and_price(fetch_sales(QUERY_URL), d)
      image_url = product['image_urls'].first.gsub('91x121','420x560')
      @p = Product.create(:name => product['name'], :description => product['description'],
                         :price => price, :image_url => image_url, 
                         :date => Date.today)
      haml :one
    else
      if d > Date.today
        @error = "You can't look into the future, silly!"
      else
        @error = "No data collected for this day."
      end

      haml :none
    end
  else
    haml :one
  end
end
