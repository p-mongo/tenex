Routes.included do

  # spawn
  get '/spawn' do
    @distros = distros_with_cache
    @keys = keys_with_cache
    @hosts = eg_client.user_hosts.sort_by do |host|
      [host.distro_id, host.started_at]
    end
    @config = SpawnConfig.first || SpawnConfig.new
    @recent_distros = SpawnedHost.recent_distros
    slim :spawn
  end

  post '/spawn' do
    payload = eg_client.spawn_host(distro_name: params[:distro],
      key_name: params[:key])
    spawn_config = SpawnConfig.first || SpawnConfig.new
    spawn_config.last_distro_name = params[:distro]
    spawn_config.last_key_name = params[:key]
    spawn_config.save!
    SpawnedHost.create!(
      distro_name: params[:distro],
      key_name: params[:key],
    )
    redirect "/spawn"
  end

  get '/spawn/:host_id/terminate' do |host_id|
    Evergreen::Host.new(eg_client, host_id).terminate
    redirect "/spawn"
  end

  get '/spawn/terminate-all' do
    eg_client.user_hosts.each do |host|
      host.terminate
    end
    redirect "/spawn"
  end

  get '/spawn/update-dns' do
    hosts = eg_client.user_hosts.sort_by do |host|
      [host.distro_id, host.started_at]
    end

    tokens = ENV.fetch('FREEDNS_TOKENS').split(',')

    hosts.each_with_index do |host, index|
      ais = Socket.getaddrinfo(host.address, 22)
      ai = ais.detect do |ai|
        ai.first == 'AF_INET'
      end
      ip = ai[2]
      token = tokens[index]
      url = "https://freedns.afraid.org/dynamic/update.php?#{token}&address=#{ip}"

      # TODO use Faraday here
      puts open(url).read
    end

    redirect '/spawn'
  end
end
