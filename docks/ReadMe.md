# Vision  

- Essentially, decisions were made towards moving full-fledged open-source project. 

# Tech 

- Another important aspect to consider, is overall tech-environmetn, since we are stating moving from 1/2 person team 
    into multi-developer distributed command
- Here we are going to outline temporary tech road-map on a scale definitly(10)/totaly-taste-based(1) aspects that are going to 
    to be considered with priorities ranging from now(10)/some-distant-time-in-future(1) as features needed in project
    - Possible public list of improvements: 
        - **Architecture dissemination**:
            - *Description*:  
            - *Necessity*: 
            - *Priority*:
        - **Network Layer**:
            - *Description*:  
            - *Necessity*: 
            - *Priority*:
        - **Data Persistence Layer**:
            - *Description*:  
            - *Necessity*: 
            - *Priority*:
        - **Ledger Providers Common Abstraction**:
            - *Description*:  
            - *Necessity*: 
            - *Priority*:
        - **Migration to SwiftUI**:
            - *Description*:  
            - *Necessity*: 
            - *Priority*:
        - **Seed phrase verification**:
            - *Description*: Check after seed phrase remembrance after generation
            - *Necessity*: 6
            - *Priority*: 3
        - **Integrate **:
            - *Description*: Check after seed phrase remembrance after generation
            - *Necessity*: 6
            - *Priority*: 3

## Tech General 

## Repository Structure

* **/Source** — исходный код проекта и кодогенерирующих утилит.

## Branching

We are going for a simplified version of a [standard(code name: successful)](https://nvie.com/posts/a-successful-git-branching-model/) git flow model:
* **master** - laster actual release in app store
* **origin/develop** — main development branches, we pour there feature branches, bugfixes, issues. Since we are currently in a rapid development state, so fore time-being this is really unstable.
* **origin/release** — release branch for prepairing release to Appstore(i.e. getting ready for master update);
* **origin/release/x.x.x** — old-releases.

## Conceptual repository structure

- Модули: это отдельные sub-module, со всеми вытикающими из этого
- В каждом модуле - циклы. - одна папочка, один цикл.
- Кроме: - Core - это главный интерактор модуля, запускается не всегда - но через него запускаются большинсво фичей из самого модуля
        - Внутри - называется полностью как сам модуль
        - Generated - это сгенерированные файлы
        - Common - делится на Общие VC, общие View, и общие элементы - например CropImage, и прочее
        
        
* __Helper__: Весь вспомогательный функционал(прокси, форматтеры, расширения и прч.)
* __BaseInterface__: Элементы интерфейса, которые шарятся между всеми остальными модулями или некоторыми их подмножествами.
* __PlanInfo__: Все что создаение проектов.
* __Profile__: Все что касается профиля пользоватля.
* __TheTourer__: Главный таргет проекта - конфигурация рута проекта, и базовые модули. 
