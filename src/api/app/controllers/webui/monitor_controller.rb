class Webui::MonitorController < Webui::WebuiController
  before_action :set_default_architecture
  before_action :require_settings, only: [:old, :index, :filtered_list, :update_building]
  before_action :fetch_workerstatus, only: [:old, :filtered_list, :update_building]
  before_action :check_ajax, only: [:update_building, :events]

  DEFAULT_SEARCH_RANGE = 24

  def old; end

  def index
    if request.post? && !params[:project].nil? && Project.valid_name?(params[:project])
      redirect_to project: params[:project]
    else
      begin
        fetch_workerstatus
      rescue Backend::NotFoundError
        @workerstatus = {}
      end

      workers = {}
      workers_list = []
      ['idle', 'building', 'away', 'down', 'dead'].each do |state|
        @workerstatus.elements(state) do |b|
          workers_list << [b['workerid'], b['hostarch']]
        end
      end
      workers_list.each do |bid, barch|
        hostname, subid = bid.gsub(%r{[:]}, '/').split('/')
        id = bid.gsub(%r{[:./]}, '_')
        workers[hostname] ||= {}
        workers[hostname]['_arch'] = barch
        workers[hostname][subid] = id
      end
      @workers_sorted = {}
      @workers_sorted = workers.sort_by { |a| a[0] } if workers
      @available_arch_list = Architecture.available.order(:name).pluck(:name)
    end
  end

  def update_building
    workers = {}
    max_time = 4 * 3600
    @workerstatus.elements('idle') do |b|
      id = b['workerid'].gsub(%r{[:./]}, '_')
      workers[id] = {}
    end

    @workerstatus.elements('building') do |b|
      id = b['workerid'].gsub(%r{[:./]}, '_')
      delta = (Time.now - Time.at(b['starttime'].to_i)).round
      delta = 5 if delta < 5
      delta = max_time if delta > max_time
      delta = (100 * Math.sin(Math.acos(1 - (Float(delta) / max_time)))).round
      delta = 100 if delta > 100
      workers[id] = { 'delta' => delta, 'project' => b['project'], 'repository' => b['repository'],
                      'package' => b['package'], 'arch' => b['arch'], 'starttime' => b['starttime'] }
    end
    # logger.debug workers.inspect
    render json: workers
  end

  def events
    data = {}

    arch = Architecture.find_by(name: params.fetch(:arch, @default_architecture))

    range = params.fetch(:range, DEFAULT_SEARCH_RANGE)

    ['waiting', 'blocked', 'squeue_high', 'squeue_med'].each do |prefix|
      data[prefix] = gethistory("#{prefix}_#{arch.name}", range).map { |time, value| [time * 1000, value] }
    end

    ['idle', 'building', 'away', 'down', 'dead'].each do |prefix|
      data[prefix] = gethistory("#{prefix}_#{arch.worker}", range).map { |time, value| [time * 1000, value] }
    end

    low = Hash[gethistory("squeue_low_#{arch}", range)]

    comb = gethistory("squeue_next_#{arch}", range).collect do |time, value|
      clow = low[time] || 0
      [1000 * time, clow + value]
    end

    data['squeue_low'] = comb
    max = add_arrays(data['squeue_high'], data['squeue_med']).map { |_, value| value }.max || 0
    data['events_max'] = max * 2
    data['jobs_max'] = maximumvalue(data['waiting']) * 2

    render json: data
  end

  private

  def gethistory(key, range)
    upper_range_limit = DEFAULT_SEARCH_RANGE * 365
    # define an upper-limit to range to avoid long running queries
    range = [upper_range_limit, range.to_i].min

    cachekey = "#{key}-#{range}"
    Rails.cache.fetch(cachekey, expires_in: (range.to_i * 3600) / 150, shared: true) do
      StatusHistory.history_by_key_and_hours(key, range).sort_by { |a| a[0] }
    end
  end

  def set_default_architecture
    @default_architecture = 'x86_64'
  end

  def fetch_workerstatus
    @workerstatus = Xmlhash.parse(WorkerStatus.hidden.to_xml)
  end

  def maximumvalue(arr)
    arr.map { |_, value| value }.max || 0
  end

  def require_settings
    @project_filter = params[:project]

    # @interval_steps must be > 0:
    # @interval_steps * @max_color + @dead_line minutes
    @interval_steps = 1
    @max_color = 240
    @time_now = Time.now
    @dead_line = 1.hour.ago
  end
end
