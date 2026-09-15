#include "../windows/host/NvencFrame.h"
#include <iostream>
#include <string>
#include <vector>
#include <algorithm>

struct Fake {
    std::vector<std::string> events;
    std::string failure;
    bool producerDone = false, mapped = false, pending = false, complete = false;
    void hit(const char* event) { events.emplace_back(event); if(failure==event)throw std::runtime_error(event); }
    void waitProducer() {hit("producer"); producerDone=true;}
    void map() {if(!producerDone)throw std::logic_error("producer still owns");hit("map");mapped=true;}
    void submit() {if(!mapped)throw std::logic_error("not mapped");pending=true;hit("submit");}
    void waitEncoder() {hit("complete");pending=false;complete=true;}
    void deliver() {if(!complete)throw std::logic_error("early output");hit("deliver");}
    void unmap() {if(pending)throw std::logic_error("encoder still owns");hit("unmap");mapped=false;}
    void quarantine() noexcept {events.emplace_back("quarantine");}
};
void require(bool value) {if(!value)throw std::runtime_error("fixture expectation failed");}
int main() {
 try {
    unsigned passed=0;
    for(int cancel=0;cancel<=3;++cancel) {
        Fake f;int calls=0;
        const auto result=spatialpc::finishNvencFrame(f,[&]{return ++calls!=cancel;});
        const std::vector<std::vector<std::string>> expected={
            {"producer","map","submit","complete","deliver","unmap"},
            {"producer"}, {"producer","map","unmap"},
            {"producer","map","submit","complete","unmap"}};
        require(f.events==expected[cancel] && result==(cancel==0));++passed;
    }
    for(const auto* failure:{"producer","map","submit","complete","deliver","unmap"}) {
        Fake f; f.failure=failure; bool failed=false;
        try{spatialpc::finishNvencFrame(f,[]{return true;});}catch(const std::runtime_error&){failed=true;}
        require(failed);
        if(f.failure=="deliver")require(f.events.back()=="unmap"&&!f.mapped);
        else require(f.events.back()=="quarantine");
        require(std::count(f.events.begin(),f.events.end(),"unmap")<=1);++passed;
    }
    // Cancellation after mapping must not retry an ambiguous failed unmap.
    Fake f;f.failure="unmap";int calls=0;bool failed=false;
    try{spatialpc::finishNvencFrame(f,[&]{return ++calls!=2;});}catch(const std::runtime_error&){failed=true;}
    require(failed&&f.events==std::vector<std::string>({"producer","map","unmap","quarantine"}));++passed;
    struct Producer {
        std::vector<std::string>& events;
        void drainAbandonedProducer() noexcept {events.emplace_back("drain");}
    };
    struct Duplication {
        std::vector<std::string>& events;
        ~Duplication(){events.emplace_back("release_dxgi");}
    };
    std::vector<std::string> order;Producer producer{order};
    try {
        Duplication dxgi{order};
        spatialpc::NvencProducerGuard<Producer> lease{&producer};
        throw std::runtime_error("conversion failed");
    }catch(const std::runtime_error&){}
    require(order==std::vector<std::string>({"drain","release_dxgi"}));++passed;
    std::cout<<"nvenc_ownership cases="<<passed<<" pass no_gpu=1\n";return 0;
 }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
