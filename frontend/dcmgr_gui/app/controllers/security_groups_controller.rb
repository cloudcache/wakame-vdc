class SecurityGroupsController < ApplicationController
  respond_to :json
  
  def index
  end
  
  # security_groups/show/1.json
  def list
    data = {
      :start => params[:start],
      :limit => params[:limit],
      :id    => params[:name]
    }
    @netfilter_group = Frontend::Models::DcmgrResource::NetfilterGroup.list(data)
    respond_with(@netfilter_group,:to => [:json])
  end
  
  # security_groups/detail/s-000001.json
  def show
    name = params[:id]
    @netfilter_group = Frontend::Models::DcmgrResource::NetfilterGroup.show(name)
    respond_with(@netfilter_group,:to => [:json])
  end
end