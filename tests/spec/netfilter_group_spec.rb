
require File.expand_path('../spec_helper', __FILE__)


describe "/api/netfilter_group" do
  it "should test CURD operations for netfilter" do
    # create not duplicated group name
    res1 = APITest.create('/netfilter_groups.json', {:description=>'g1', :rule => "tcp:22,22,ip4:0.0.0.0"})
    res1.success?.should be_true
    APITest.get("/netfilter_groups/#{res1["uuid"]}").success?.should be_true

    res2 = APITest.create('/netfilter_groups.json', {:description=>'g2', :rule => "icmp:-1,-1,#{res1["uuid"]}\ntcp:22,22,#{res1["uuid"]}"})
    res2.success?.should be_true
    APITest.get("/netfilter_groups/#{res2["uuid"]}").success?.should be_true

    res3 = APITest.create('/netfilter_groups.json', {:description=>'g3', :rule => "icmp:-1,-1,#{res2["uuid"]}\ntcp:22,22,#{res2["uuid"]}"})
    res3.success?.should be_true
    APITest.get("/netfilter_groups/#{res3["uuid"]}").success?.should be_true

    # update created groups 
    APITest.update("/netfilter_groups/#{res1["uuid"]}", {:description=>'g1(new)', :rule => "icmp:-1,-1,ip4:0.0.0.0"}).success?.should be_true
    APITest.update("/netfilter_groups/#{res2["uuid"]}", {:description=>'g2(new)', :rule => "tcp:80,80,ip4:0.0.0.0"}).success?.should be_true
    APITest.update("/netfilter_groups/#{res3["uuid"]}", {:description=>'g3(new)', :rule => "udp:53,53,ip4:0.0.0.0"}).success?.should be_true

    # delete
    APITest.delete("/netfilter_groups/#{res3["uuid"]}").success?.should be_true
    APITest.delete("/netfilter_groups/#{res2["uuid"]}").success?.should be_true
    APITest.delete("/netfilter_groups/#{res1["uuid"]}").success?.should be_true
  end
end