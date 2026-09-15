// Compile/run against the external exact Manager6.1.0 header; never link its DLL.
#include <NvStreamManagerClient.h>
#include <cstddef>
#include <cstdio>
static_assert(sizeof(nv_service_status_t)==16656);
static_assert(offsetof(nv_service_status_t,openxr_log_file_path)==3);
static_assert(offsetof(nv_service_status_t,openxr_log_file_path_length)==264);
static_assert(offsetof(nv_service_status_t,reserved)==272);
int main(){std::puts("PASS native Manager6.1.0 status ABI: size16656 offsets3/264/272; no DLL loaded");}
