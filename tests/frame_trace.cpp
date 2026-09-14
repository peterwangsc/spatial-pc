#include <iostream>
#include <sstream>
#include <stdexcept>
#include <thread>
#include "../windows/host/FrameTrace.h"
void require(bool value,const char* message){if(!value)throw std::runtime_error(message);}
int main(){try{
    FrameTrace disabled(false,100,1000);std::ostringstream empty;
    disabled.record(FrameTrace::Kind::Encoded,110,7);disabled.report(empty);
    require(empty.str().empty(),"Disabled trace must produce no output");
    FrameTrace ordered(true,100,1000);std::ostringstream result;
    ordered.record(FrameTrace::Kind::Encoded,130,7);
    ordered.record(FrameTrace::Kind::Acquired,110,7);
    ordered.record(FrameTrace::Kind::WriteEnter,120,7);ordered.report(result);
    const auto text=result.str();
    require(text.find("acquired")<text.find("write_enter")&&text.find("write_enter")<text.find("encoded"),"Recorded order must be QPC time order");
    require(text.find("\"ticks\":10,\"pts_100ns\":7")!=std::string::npos,"Retain exact relative ticks and frame identity");
    FrameTrace bounded(true,0,1000);std::vector<std::thread> writers;
    for(int thread=0;thread<3;++thread)writers.emplace_back([&,thread]{for(int i=0;i<4000;++i)bounded.record(FrameTrace::Kind::Encoded,thread*4000+i,i);});
    for(auto& writer:writers)writer.join();
    std::ostringstream full;bounded.report(full);const auto output=full.str();
    require(output.find("\"omitted\":3808")!=std::string::npos,"Concurrent overflow count must be exact");
    size_t count=0,offset=0;while((offset=output.find("\"event\":",offset))!=std::string::npos){++count;++offset;}
    require(count==FrameTrace::limit,"Concurrent storage must remain bounded");
    std::cout<<"PASS: disabled trace, QPC ordering, frame identity, concurrent bound and overflow count\n";
    return 0;
}catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}}
