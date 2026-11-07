/* Mirsa's own minimal ordered loader. No LCSign/ESign code or binaries. */
/* ABI declarations match Darwin public dlfcn/stdio/stdlib interfaces. Keeping
 * this file freestanding lets Linux clang produce iOS code without SDK copies. */
typedef unsigned long size_t;
typedef struct { const char *dli_fname; void *dli_fbase; const char *dli_sname; void *dli_saddr; } Dl_info;
extern int dladdr(const void *, Dl_info *);
extern void *dlopen(const char *, int);
extern char *realpath(const char *, char *);
extern void *fopen(const char *, const char *);
extern size_t fread(void *, size_t, size_t, void *);
extern int fclose(void *);
extern int fgetc(void *);
extern int ferror(void *);
extern int snprintf(char *, size_t, const char *, ...);
#define LIMIT 64
#define PATHLEN 1024
/* Constructor-only state, no mutable files, network, UI, crash handlers or
 * unloading. A failed dlopen stops later entries; already-run initializers
 * cannot be undone safely. Re-sign/reinstall is required for configuration. */
static int entered;
static char entries[LIMIT][PATHLEN];
static int safe(const char *s) {
    unsigned n=0, segment=0;
    if (!s[0] || s[0]=='/') return 0;
    for (;s[n];++n) {
        unsigned char c=(unsigned char)s[n];
        if(n>=PATHLEN-1) return 0;
        if(c=='/') { if(!segment) return 0; segment=0; }
        else { if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-'||c=='.'))return 0; ++segment; }
        if(c=='.'&&(n==0||s[n-1]=='/')&&(s[n+1]==0||s[n+1]=='/'||(s[n+1]=='.'&&(s[n+2]==0||s[n+2]=='/'))))return 0;
    }
    return segment!=0;
}
static int equal(const char*a,const char*b) { unsigned i=0;while(a[i]&&a[i]==b[i])++i;return a[i]==b[i]; }
static int inside(const char*p,const char*base) { unsigned i=0;while(base[i]&&p[i]==base[i])++i;return !base[i]&&p[i]=='/'; }
static void mirsa_load(void) __attribute__((constructor));
static void mirsa_load(void) {
    if(__atomic_exchange_n(&entered,1,__ATOMIC_ACQ_REL))return;
    Dl_info info;
    char self[PATHLEN], base[PATHLEN], file[PATHLEN], candidate[PATHLEN];
    if(!dladdr((const void*)&mirsa_load,&info)||!info.dli_fname||!realpath(info.dli_fname,self))return;
    unsigned end=0; for(unsigned i=0;self[i];++i)if(self[i]=='/')end=i;
    if(!end)return;
    for(unsigned i=0;i<end;++i)base[i]=self[i];base[end]=0;
    int len=snprintf(file,sizeof(file),"%s/MirsaLoadOrder.txt",base);
    if(len<0||len>=PATHLEN)return;
    void*f=fopen(file,"rb"); if(!f)return;
    char data[LIMIT*PATHLEN+1];
    size_t size=fread(data,1,sizeof(data),f);
    int bad=ferror(f)||size==sizeof(data)||fgetc(f)!=-1;
    fclose(f); if(bad||!size||data[size-1]!='\n')return;
    unsigned count=0,pos=0;
    for(size_t i=0;i<size;++i){
        if(data[i]=='\n'){
            if(count==LIMIT||!pos)return;
            entries[count][pos]=0;
            if(!safe(entries[count]))return;
            for(unsigned j=0;j<count;++j)if(equal(entries[j],entries[count]))return;
            len=snprintf(file,sizeof(file),"%s/%s",base,entries[count]);
            if(len<0||len>=PATHLEN||!realpath(file,candidate)||!inside(candidate,base))return;
            ++count;pos=0;
        }else{
            if(count==LIMIT||pos>=PATHLEN-1||!data[i])return;
            entries[count][pos++]=data[i];
        }
    }
    /* All paths validated before any user initializer runs. Darwin RTLD_NOW=2,
     * RTLD_GLOBAL=8. Dependencies can run first, so packaging rejects forward
     * root dependencies and cycles. Handles intentionally live until exit. */
    for(unsigned i=0;i<count;++i){
        len=snprintf(file,sizeof(file),"%s/%s",base,entries[i]);
        if(len<0||len>=PATHLEN||!dlopen(file,2|8))return;
    }
}
